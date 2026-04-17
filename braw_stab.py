"""
braw_stab.py — BRAW IMU → stabilization correction quaternions.

Minimal extract of the two pieces from the parent DualFish app that this
tool needs:
  • BrawDecoder   — runs `braw_helper --info` / `--gyro` via subprocess
  • BrawGyroStabilizer — VQF fusion + velocity-dampened smoothing, outputs
                         per-frame 3×3 correction matrices.

Everything else from vr180_gui.py (OpenCV preview, MLX/Numba accelerators,
frame decoding, rolling-shutter correction, the Qt app itself) is dropped.
"""

from __future__ import annotations
import json
import math
import subprocess
import sys
from pathlib import Path

import numpy as np


# ─── BRAW subprocess wrapper ────────────────────────────────────────────

class BrawDecoder:
    """Wraps the sibling `braw_helper` binary to pull metadata + gyro data
    out of a Blackmagic RAW file. Frame decoding is intentionally omitted;
    we only need the IMU."""

    def __init__(self, braw_path):
        self.path = str(braw_path)
        self._helper = self._find_helper()
        if self._helper is None:
            raise RuntimeError("braw_helper binary not found next to this script")
        self._info = None

    @staticmethod
    def _find_helper():
        # Candidates, in order: PyInstaller frozen bundle (sys._MEIPASS),
        # next-to-script (dev mode), next-to-executable (py2app-style).
        candidates = []
        meipass = getattr(sys, "_MEIPASS", None)
        if meipass:
            candidates.append(Path(meipass) / "braw_helper")
        candidates.append(Path(__file__).resolve().parent / "braw_helper")
        candidates.append(Path(sys.executable).resolve().parent / "braw_helper")
        for c in candidates:
            if c.exists():
                return str(c)
        return None

    def get_info(self) -> dict:
        if self._info:
            return self._info
        r = subprocess.run([self._helper, "--info", self.path],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            raise RuntimeError(f"braw_helper --info failed: {r.stderr}")
        self._info = json.loads(r.stdout)
        return self._info

    def get_gyro_data(self):
        """Return (Nx6 float32 array [gx,gy,gz,ax,ay,az], header_dict)."""
        p = subprocess.Popen([self._helper, "--gyro", self.path],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = p.communicate(timeout=120)
        if p.returncode != 0:
            raise RuntimeError(f"braw_helper --gyro failed: {stderr.decode()}")
        # stderr may carry non-JSON lines (e.g. objc class-conflict warnings
        # when a separate BlackmagicRawAPI framework is also installed on
        # the host). Pick the actual JSON header — the first line that
        # starts with '{'.
        stderr_text = stderr.decode(errors='replace')
        json_line = next(
            (ln for ln in stderr_text.splitlines() if ln.lstrip().startswith('{')),
            None)
        if json_line is None:
            raise RuntimeError(
                f"braw_helper --gyro: no JSON header in stderr:\n{stderr_text[:500]}")
        header = json.loads(json_line)
        if header['sample_count'] == 0:
            return np.empty((0, 6), dtype=np.float32), header
        data = np.frombuffer(stdout, dtype='<f4').reshape(-1, 6)
        return data, header


# ─── Gyro stabilization ────────────────────────────────────────────────

def _smooth_quats_velocity_dampened(quats, fps, smooth_ms, fast_ms=50.0,
                                     max_velocity=200.0, max_corr_deg=10.0,
                                     responsiveness=1.0):
    """Bidirectional exponential quaternion smoothing that relaxes toward
    `fast_ms` when the camera is moving quickly and `smooth_ms` when it's
    still. Same algorithm the GoPro/DJI GyroStabilizer uses."""
    N = len(quats)
    if N < 2:
        return quats.copy()

    dt = 1.0 / fps

    # Per-frame angular velocity (vectorized)
    dots = np.abs(np.clip(np.sum(quats[:-1] * quats[1:], axis=1), -1.0, 1.0))
    velocities = np.zeros(N, dtype=np.float64)
    velocities[1:] = np.degrees(2.0 * np.arccos(dots)) / dt

    # Smooth the velocity signal itself (200 ms bidirectional)
    vel_alpha = min(1.0, dt / 0.2)
    vel_decay = 1.0 - vel_alpha
    for i in range(1, N):
        velocities[i] = velocities[i-1] * vel_decay + velocities[i] * vel_alpha
    for i in range(N-2, -1, -1):
        velocities[i] = velocities[i+1] * vel_decay + velocities[i] * vel_alpha

    # Per-frame alpha: blends tau_smooth with tau_fast based on velocity
    tau_smooth = smooth_ms / 1000.0
    tau_fast = fast_ms / 1000.0
    resp_power = max(0.1, responsiveness)
    if max_velocity > 0:
        vel_linear = np.clip(velocities / max_velocity, 0.0, 1.0)
    else:
        vel_linear = np.zeros(N)
    taus = tau_smooth * (1.0 - vel_linear ** resp_power) + tau_fast * vel_linear ** resp_power
    alphas = np.clip(dt / (taus + dt), 0.0, 1.0)

    # Forward and backward NLERP passes
    fwd = quats.copy()
    for i in range(1, N):
        a = alphas[i]
        q = fwd[i-1] * (1.0 - a) + quats[i] * a
        fwd[i] = q / np.linalg.norm(q)
    bwd = quats.copy()
    for i in range(N-2, -1, -1):
        a = alphas[i]
        q = bwd[i+1] * (1.0 - a) + quats[i] * a
        bwd[i] = q / np.linalg.norm(q)

    # Average fwd + bwd
    smoothed = fwd + bwd
    norms = np.linalg.norm(smoothed, axis=1, keepdims=True)
    norms[norms < 1e-10] = 1.0
    smoothed /= norms

    # Soft-elastic correction limit
    if max_corr_deg > 0:
        max_corr_rad = math.radians(max_corr_deg)
        dots_corr = np.sum(quats * smoothed, axis=1)
        flip = dots_corr < 0
        smoothed[flip] = -smoothed[flip]
        dots_corr = np.clip(np.abs(dots_corr), 0.0, 1.0)
        angles_corr = 2.0 * np.arccos(dots_corr)
        for i in np.nonzero(angles_corr > max_corr_rad)[0]:
            angle = angles_corr[i]
            soft = max_corr_rad * (1.0 + math.log(angle / max_corr_rad))
            t = min(soft / angle, 1.0)
            q = quats[i] * (1.0 - t) + smoothed[i] * t
            smoothed[i] = q / np.linalg.norm(q)

    norms = np.linalg.norm(smoothed, axis=1, keepdims=True)
    norms[norms < 1e-10] = 1.0
    smoothed /= norms
    return smoothed


class BrawGyroStabilizer:
    """Fuse BRAW gyro+accel via VQF, then compute per-frame correction
    rotation matrices. `smooth()` is the only entry point the exporter uses.

    IMU → camera-sensor axis fix for BMD Immersive is empirically
    `negate Y`, verified via NCC optimization in the parent app."""

    C_IMU_TO_CAM = np.array([[1, 0, 0], [0, -1, 0], [0, 0, 1]], dtype=np.float64)

    def __init__(self, gyro, accel, gyro_rate, fps, num_frames):
        self.gyro = np.asarray(gyro, dtype=np.float64)
        self.accel = np.asarray(accel, dtype=np.float64)
        self.gyro_rate = float(gyro_rate)
        self.fps = float(fps)
        self.num_frames = int(num_frames)
        self.dt_imu = 1.0 / self.gyro_rate
        M = len(self.gyro)

        # Fuse gyro + accel → orientation quaternions via VQF
        from vqf import offlineVQF
        result = offlineVQF(
            np.ascontiguousarray(self.gyro),
            np.ascontiguousarray(self.accel),
            None, self.dt_imu)
        quats = result['quat6D']  # (M, 4) w,x,y,z

        # Mid-frame quaternion per video frame
        frame_dur = 1.0 / self.fps
        self.frame_quats = np.zeros((self.num_frames, 4), dtype=np.float64)
        for fi in range(self.num_frames):
            t_mid = (fi + 0.5) * frame_dur
            idx = max(0, min(int(round(t_mid * self.gyro_rate)), M - 1))
            self.frame_quats[fi] = quats[idx]

        self.corr_matrices = [np.eye(3) for _ in range(self.num_frames)]

    def smooth(self, window_ms=0.0, horizon_lock=False,
                max_corr_deg=10.0, responsiveness=1.0):
        """Produce per-frame 3×3 correction matrices. If `window_ms == 0`,
        fully lock to the first frame (camera lock); otherwise smooth toward
        a velocity-dampened reference trajectory."""
        N = self.num_frames
        if N == 0:
            return

        # Normalize, fix hemisphere
        Q = self.frame_quats.copy()
        for i in range(N):
            Q[i] /= max(np.linalg.norm(Q[i]), 1e-10)
        for i in range(1, N):
            if np.dot(Q[i], Q[i-1]) < 0:
                Q[i] *= -1

        # Reference trajectory
        if window_ms > 0 and N > 1:
            Q_ref = _smooth_quats_velocity_dampened(
                Q, self.fps, smooth_ms=window_ms, fast_ms=50.0,
                max_velocity=200.0, max_corr_deg=max_corr_deg,
                responsiveness=responsiveness)
        else:
            Q_ref = np.tile(Q[0], (N, 1))

        # Q_corr = Q_raw⁻¹ · Q_ref
        Q_inv = Q.copy()
        Q_inv[:, 1:] = -Q_inv[:, 1:]
        w1, x1, y1, z1 = Q_inv.T
        w2, x2, y2, z2 = Q_ref.T
        cw = w1*w2 - x1*x2 - y1*y2 - z1*z2
        cx = w1*x2 + x1*w2 + y1*z2 - z1*y2
        cy = w1*y2 - x1*z2 + y1*w2 + z1*x2
        cz = w1*z2 + x1*y2 - y1*x2 + z1*w2

        # Quaternion → rotation matrix
        w, x, y, z = cw, cx, cy, cz
        R = np.zeros((N, 3, 3), dtype=np.float64)
        R[:, 0, 0] = 1 - 2*(y*y + z*z)
        R[:, 0, 1] = 2*(x*y - w*z)
        R[:, 0, 2] = 2*(x*z + w*y)
        R[:, 1, 0] = 2*(x*y + w*z)
        R[:, 1, 1] = 1 - 2*(x*x + z*z)
        R[:, 1, 2] = 2*(y*z - w*x)
        R[:, 2, 0] = 2*(x*z - w*y)
        R[:, 2, 1] = 2*(y*z + w*x)
        R[:, 2, 2] = 1 - 2*(x*x + y*y)

        C = self.C_IMU_TO_CAM
        R_cam = np.einsum('ij,njk,lk->nil', C, R, C)

        # Optional horizon lock: de-roll so gravity stays vertical in output
        if horizon_lock:
            qw, qx, qy, qz = Q.T
            R_raw = np.zeros((N, 3, 3), dtype=np.float64)
            R_raw[:, 0, 0] = 1 - 2*(qy*qy + qz*qz)
            R_raw[:, 0, 1] = 2*(qx*qy - qw*qz)
            R_raw[:, 0, 2] = 2*(qx*qz + qw*qy)
            R_raw[:, 1, 0] = 2*(qx*qy + qw*qz)
            R_raw[:, 1, 1] = 1 - 2*(qx*qx + qz*qz)
            R_raw[:, 1, 2] = 2*(qy*qz - qw*qx)
            R_raw[:, 2, 0] = 2*(qx*qz - qw*qy)
            R_raw[:, 2, 1] = 2*(qy*qz + qw*qx)
            R_raw[:, 2, 2] = 1 - 2*(qx*qx + qy*qy)
            g_world = np.array([0.0, 0.0, -1.0])
            g_cam = np.einsum('ij,nj->ni', C, np.einsum('nji,j->ni', R_raw, g_world))
            g_out = np.einsum('nji,nj->ni', R_cam, g_cam)
            rolls = np.arctan2(g_out[:, 0], -g_out[:, 1])
            c_r, s_r = np.cos(rolls), np.sin(rolls)
            D = np.zeros((N, 3, 3), dtype=np.float64)
            D[:, 0, 0] = c_r; D[:, 0, 1] = -s_r
            D[:, 1, 0] = s_r; D[:, 1, 1] = c_r
            D[:, 2, 2] = 1.0
            R_cam = np.einsum('nij,njk->nik', R_cam, D)

        self.corr_matrices = [R_cam[i] for i in range(N)]
