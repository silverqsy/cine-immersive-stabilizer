#!/usr/bin/env python3
"""
Cine Immersive Stabilizer — stabilize a single BRAW and emit a Fusion
PanoMap node (with keyed Rotate.X/Y/Z splines) that the user pastes into
Resolve's Fusion page.

Flow:
  1. User picks a BRAW file.
  2. App extracts the IMU, runs the VQF-based stabilization (same pipeline
     as the main DualFish Silver Bullet app), and produces a per-source-frame
     (tilt, pan, roll) angle list.
  3. User chooses either:
       • Save .setting file   → dragged into the Fusion view, or
       • Copy to clipboard    → Edit → Paste Settings inside Fusion.

The output is just Lua — no DRT container, no binary blob, no hidden
length/hash fields — so Fusion loads it without any validation games.
"""

from __future__ import annotations
import sys
import traceback
from pathlib import Path

# Make sure sibling modules import cleanly regardless of CWD
_THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_THIS_DIR))

import numpy as np
from PyQt6.QtCore import Qt, QThread, pyqtSignal
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QPushButton, QLabel, QFileDialog, QDoubleSpinBox, QCheckBox, QProgressBar,
    QTextEdit, QMessageBox, QGroupBox,
)

from braw_stab import BrawGyroStabilizer, BrawDecoder  # noqa: E402
from panomap_setting import build_panomap_setting  # noqa: E402


# ─── Stabilization ──────────────────────────────────────────────────────

def rot_to_tilt_pan_roll(R: np.ndarray) -> tuple[float, float, float]:
    """3x3 correction matrix → (Tilt_X, Pan_Y, Roll_Z) degrees, ZYX order —
    matches PanoMap's default Euler rotation order. Roll is negated because
    PanoMap's Z axis runs opposite to the stabilizer's; tilt and pan match.
    """
    pan_y = -float(np.degrees(np.arcsin(np.clip(R[2, 0], -1.0, 1.0))))
    tilt_x = float(np.degrees(np.arctan2(R[2, 1], R[2, 2])))
    roll_z = -float(np.degrees(np.arctan2(R[1, 0], R[0, 0])))
    return tilt_x, pan_y, roll_z


def stabilize_braw(braw_path: Path, smooth_ms: float, horizon_lock: bool,
                    max_corr_deg: float, responsiveness: float,
                    status_cb=lambda s: None):
    decoder = BrawDecoder(str(braw_path))
    info = decoder.get_info()
    fps = float(info.get('frame_rate', 30.0))
    n_frames = int(info.get('frame_count', 0))
    if info.get('gyro_sample_count', 0) == 0:
        raise RuntimeError(f"No gyro data in {braw_path.name}")

    status_cb(f"  Extracting gyro … ({info['gyro_sample_count']} samples @ "
              f"{info['gyro_sample_rate']:.0f} Hz)")
    imu, hdr = decoder.get_gyro_data()
    gyro = imu[:, :3].copy()
    accel = imu[:, 3:].copy()
    gyro_rate = float(hdr['gyro_sample_rate'])

    status_cb("  Running VQF fusion + stabilization …")
    stab = BrawGyroStabilizer(gyro, accel, gyro_rate, fps, n_frames)
    stab.smooth(window_ms=smooth_ms, horizon_lock=horizon_lock,
                max_corr_deg=max_corr_deg, responsiveness=responsiveness)

    angles = [rot_to_tilt_pan_roll(R) for R in stab.corr_matrices]
    return angles, info, fps, n_frames


# ─── Worker thread ──────────────────────────────────────────────────────

class ProcessWorker(QThread):
    log = pyqtSignal(str)
    progress = pyqtSignal(str)
    finished_ok = pyqtSignal(str)           # setting file text
    finished_err = pyqtSignal(str)

    def __init__(self, braw_path: Path, smooth_ms: float, horizon_lock: bool,
                 max_corr_deg: float, responsiveness: float,
                 yaw_off: float, tilt_off: float, roll_off: float):
        super().__init__()
        self.braw_path = braw_path
        self.smooth_ms = smooth_ms
        self.horizon_lock = horizon_lock
        self.max_corr_deg = max_corr_deg
        self.responsiveness = responsiveness
        self.yaw_off = yaw_off       # +right
        self.tilt_off = tilt_off     # +up
        self.roll_off = roll_off     # +clockwise

    def run(self):
        try:
            self.progress.emit(f"Stabilizing {self.braw_path.name} …")
            self.log.emit(f"▸ {self.braw_path.name}")
            angles, info, fps, n = stabilize_braw(
                self.braw_path, self.smooth_ms, self.horizon_lock,
                self.max_corr_deg, self.responsiveness,
                status_cb=lambda s: self.log.emit(s))

            # Global 3-axis offsets, applied per-frame. Convention:
            #   yaw+ = right  → Rotate.Y
            #   tilt+ = up    → Rotate.X
            #   roll+ = CW    → Rotate.Z
            n_kf = len(angles)
            tilt_kfs = [(i, a[0] + self.tilt_off) for i, a in enumerate(angles)]
            pan_kfs  = [(i, a[1] + self.yaw_off)  for i, a in enumerate(angles)]
            roll_kfs = [(i, a[2] + self.roll_off) for i, a in enumerate(angles)]

            self.log.emit(
                f"  {n_kf} keyframes  @ {fps:.2f} fps  "
                f"(Tilt {min(t for _,t in tilt_kfs):+.2f}..{max(t for _,t in tilt_kfs):+.2f}°, "
                f"Pan {min(p for _,p in pan_kfs):+.2f}..{max(p for _,p in pan_kfs):+.2f}°, "
                f"Roll {min(r for _,r in roll_kfs):+.2f}..{max(r for _,r in roll_kfs):+.2f}°)")

            setting = build_panomap_setting(tilt_kfs, pan_kfs, roll_kfs)
            self.finished_ok.emit(setting)

        except Exception as e:
            self.finished_err.emit(f"{e}\n{traceback.format_exc()}")


# ─── GUI ────────────────────────────────────────────────────────────────

class StabilizeWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Cine Immersive Stabilizer — by Siyang Qi")
        self.resize(820, 560)
        self.braw_path: Path | None = None
        self.setting_text: str | None = None
        self.worker: ProcessWorker | None = None

        root = QWidget()
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)

        # File picker row
        row = QHBoxLayout()
        self.open_btn = QPushButton("Open BRAW…")
        self.open_btn.clicked.connect(self.on_open)
        row.addWidget(self.open_btn)
        self.file_label = QLabel("No BRAW loaded")
        self.file_label.setStyleSheet("color: #888;")
        row.addWidget(self.file_label, 1)
        outer.addLayout(row)

        # Stabilization settings
        grp = QGroupBox("Stabilization settings")
        grid = QGridLayout(grp)

        grid.addWidget(QLabel("Smoothing window (ms, 0 = camera lock):"), 0, 0)
        self.smooth_spin = QDoubleSpinBox()
        self.smooth_spin.setRange(0.0, 5000.0)
        self.smooth_spin.setDecimals(0)
        self.smooth_spin.setSingleStep(50)
        self.smooth_spin.setValue(1000)
        self.smooth_spin.setToolTip("0 = camera-lock (full stabilization). "
                                     ">0 = velocity-dampened smoothing.")
        grid.addWidget(self.smooth_spin, 0, 1)

        grid.addWidget(QLabel("Max correction (°):"), 0, 2)
        self.maxcorr_spin = QDoubleSpinBox()
        self.maxcorr_spin.setRange(0.0, 180.0)
        self.maxcorr_spin.setDecimals(1)
        self.maxcorr_spin.setSingleStep(1.0)
        self.maxcorr_spin.setValue(15.0)
        grid.addWidget(self.maxcorr_spin, 0, 3)

        grid.addWidget(QLabel("Responsiveness:"), 1, 0)
        self.resp_spin = QDoubleSpinBox()
        self.resp_spin.setRange(0.2, 3.0)
        self.resp_spin.setDecimals(2)
        self.resp_spin.setSingleStep(0.1)
        self.resp_spin.setValue(1.0)
        grid.addWidget(self.resp_spin, 1, 1)

        self.horizon_cb = QCheckBox("Horizon lock")
        grid.addWidget(self.horizon_cb, 1, 2, 1, 2)
        outer.addWidget(grp)

        # Global 3-axis offset — applied to every keyframe
        grp_off = QGroupBox("Global offset (added to every frame)")
        goff = QGridLayout(grp_off)
        goff.addWidget(QLabel("Yaw (°):"), 0, 0)
        self.yaw_spin = QDoubleSpinBox()
        self.yaw_spin.setRange(-180.0, 180.0)
        self.yaw_spin.setDecimals(2)
        self.yaw_spin.setSingleStep(0.5)
        self.yaw_spin.setValue(0.0)
        goff.addWidget(self.yaw_spin, 0, 1)

        goff.addWidget(QLabel("Tilt (°):"), 0, 2)
        self.tilt_spin = QDoubleSpinBox()
        self.tilt_spin.setRange(-180.0, 180.0)
        self.tilt_spin.setDecimals(2)
        self.tilt_spin.setSingleStep(0.5)
        self.tilt_spin.setValue(0.0)
        goff.addWidget(self.tilt_spin, 0, 3)

        goff.addWidget(QLabel("Roll (°):"), 0, 4)
        self.roll_spin = QDoubleSpinBox()
        self.roll_spin.setRange(-180.0, 180.0)
        self.roll_spin.setDecimals(2)
        self.roll_spin.setSingleStep(0.5)
        self.roll_spin.setValue(0.0)
        goff.addWidget(self.roll_spin, 0, 5)
        outer.addWidget(grp_off)

        # Process row
        row3 = QHBoxLayout()
        self.process_btn = QPushButton("Stabilize")
        self.process_btn.setEnabled(False)
        self.process_btn.clicked.connect(self.on_process)
        row3.addWidget(self.process_btn)

        self.save_btn = QPushButton("Save .setting…")
        self.save_btn.setEnabled(False)
        self.save_btn.clicked.connect(self.on_save)
        row3.addWidget(self.save_btn)

        self.clipboard_btn = QPushButton("Copy to clipboard")
        self.clipboard_btn.setEnabled(False)
        self.clipboard_btn.clicked.connect(self.on_clipboard)
        row3.addWidget(self.clipboard_btn)
        outer.addLayout(row3)

        # Progress + log
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)   # indeterminate by default
        self.progress.setVisible(False)
        outer.addWidget(self.progress)

        self.log_box = QTextEdit()
        self.log_box.setReadOnly(True)
        self.log_box.setStyleSheet("font-family: monospace; font-size: 11px;")
        outer.addWidget(self.log_box, 1)

        # Usage hint
        hint = QLabel(
            "1. Create a timeline in DaVinci with the BRAW — don't trim yet.\n"
            "2. Load the same BRAW in this app and click Stabilize.\n"
            "3. Paste the node into the Fusion tab — one for each eye.\n"
            "4. Trim the clip afterwards if needed."
        )
        hint.setStyleSheet("color: #888; font-size: 11px;")
        hint.setWordWrap(True)
        outer.addWidget(hint)

        # Shameless plug
        plug = QLabel(
            "Shameless Plug: Want to shoot VR180 without hauling a Cine "
            "Immersive? Check out my modded compact VR180 cameras!"
        )
        plug.setStyleSheet("color: #888; font-size: 11px; padding-top: 2px;")
        plug.setWordWrap(True)
        outer.addWidget(plug)

    def log(self, msg: str):
        self.log_box.append(msg)

    # ── Handlers ─────────────────────────────────────────────────────

    def on_open(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Open BRAW", "",
            "BRAW (*.braw);;All Files (*)")
        if not path:
            return
        self.braw_path = Path(path)
        self.file_label.setText(str(self.braw_path))
        self.file_label.setStyleSheet("")
        self.process_btn.setEnabled(True)
        # Invalidate previous result
        self.setting_text = None
        self.save_btn.setEnabled(False)
        self.clipboard_btn.setEnabled(False)
        self.log(f"Loaded: {self.braw_path}")

    def on_process(self):
        if not self.braw_path:
            return
        self.process_btn.setEnabled(False)
        self.save_btn.setEnabled(False)
        self.clipboard_btn.setEnabled(False)
        self.open_btn.setEnabled(False)
        self.progress.setVisible(True)
        self.log_box.clear()

        self.worker = ProcessWorker(
            self.braw_path,
            smooth_ms=self.smooth_spin.value(),
            horizon_lock=self.horizon_cb.isChecked(),
            max_corr_deg=self.maxcorr_spin.value(),
            responsiveness=self.resp_spin.value(),
            yaw_off=self.yaw_spin.value(),
            tilt_off=self.tilt_spin.value(),
            roll_off=self.roll_spin.value())
        self.worker.log.connect(self.log)
        self.worker.progress.connect(self.statusBar().showMessage)
        self.worker.finished_ok.connect(self.on_finished_ok)
        self.worker.finished_err.connect(self.on_finished_err)
        self.worker.start()

    def on_finished_ok(self, setting_text: str):
        self.setting_text = setting_text
        self.progress.setVisible(False)
        self.process_btn.setEnabled(True)
        self.open_btn.setEnabled(True)
        self.save_btn.setEnabled(True)
        self.clipboard_btn.setEnabled(True)
        self.statusBar().showMessage("Ready — save or copy to clipboard.")
        self.log("\n✅ PanoMap node ready.")

    def on_finished_err(self, msg: str):
        self.progress.setVisible(False)
        self.process_btn.setEnabled(True)
        self.open_btn.setEnabled(True)
        self.statusBar().showMessage("Failed")
        self.log(f"\n❌ {msg}")

    def on_save(self):
        if not self.setting_text:
            return
        default_name = (self.braw_path.stem + ".setting") if self.braw_path else "PanoMap.setting"
        path, _ = QFileDialog.getSaveFileName(
            self, "Save Fusion Setting", default_name,
            "Fusion Setting (*.setting);;All Files (*)")
        if not path:
            return
        p = Path(path)
        if p.suffix.lower() != '.setting':
            p = p.with_suffix('.setting')
        p.write_text(self.setting_text, encoding='utf-8')
        self.log(f"💾 Saved → {p}")
        self.statusBar().showMessage(f"Saved: {p}")

    def on_clipboard(self):
        if not self.setting_text:
            return
        QGuiApplication.clipboard().setText(self.setting_text)
        self.log("📋 Copied to clipboard. In Fusion: Edit → Paste Settings.")
        self.statusBar().showMessage("Copied to clipboard")


def main():
    app = QApplication(sys.argv)
    win = StabilizeWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
