# Cine Immersive Stabilizer

Gyro-based rotation stabilization for Blackmagic URSA Cine Immersive (BRAW)
footage. Reads the camera's embedded IMU, runs VQF orientation fusion, and
emits a Fusion `PanoMap` node with keyframed Rotate.X/Y/Z that you paste
into Resolve's Fusion page — no re-render, full grade pipeline intact.

## Install (end users)

**Do not clone this repo** — grab the prebuilt app instead:

1. Go to [Releases](https://github.com/silverqsy/cine-immersive-stabilizer/releases/latest).
2. Download **`CineImmersiveStabilizer.zip`** and unzip.
3. Move **Cine Immersive Stabilizer.app** to /Applications.
4. Launch. The app is signed + notarized — no Gatekeeper warning.

macOS Apple Silicon (arm64) only. macOS 13.0+.

## Build from source

Native SwiftUI app. VQF gyro fusion is linked from upstream C++ source.

```bash
cd swift
./build.sh       # swift build + sign + notarize (needs Developer ID)
```

Or just `swift build -c release` for a quick local dev binary. Set the
`BRAW_HELPER` env var to point at the helper when running the dev binary
outside the .app bundle.

## Usage

1. Click **Open BRAW…**, pick a `.braw` clip.
2. Adjust stabilization settings (or leave defaults for camera lock).
3. Click **Stabilize**.
4. Either **Save .setting…** to a file, or **Copy to clipboard**.

In Resolve's Fusion page for that clip:
- Drag the `.setting` file into the Fusion view, **or**
- `Edit → Paste Settings` (if you used the clipboard button).

You get one `PanoMap1` node with three keyed `BezierSpline`s on
Rotate.X/Y/Z. Wire `MediaIn → PanoMap1 → MediaOut` and you're done.

## Settings

| Control | What it does |
|---|---|
| Smoothing window (ms) | `0` = full camera lock (every rotation cancelled). `>0` = velocity-dampened smoothing — follows intentional pans/tilts, rejects shake. Typical: 200–1000 ms. |
| Max correction (°) | Soft elastic limit. Corrections beyond this are logarithmically clamped so the image doesn't swing wildly during fast motion. |
| Responsiveness | How aggressively the smoother switches from "smooth" to "fast" mode with angular velocity. `1.0` = default. |
| Horizon lock | De-roll so gravity stays vertical in the output. |

## Files

| File | Role |
|---|---|
| `swift/Package.swift` | SPM manifest. |
| `swift/Sources/CineImmersiveStabilizer/` | SwiftUI app + stabilization pipeline. |
| `swift/Sources/VQFC/` | C++ VQF source + C-ABI shim, compiled into the Swift target. |
| `swift/build.sh` | Full build → sign → notarize pipeline. |
| `braw_helper` | C++ binary (Blackmagic RAW SDK, arm64 macOS). Extracts IMU + metadata. Bundled inside the app; source lives in the parent DualFish project. |
| `entitlements.plist` | Hardened-runtime entitlements for codesigning. |

## Third-party

VQF (MIT, © Daniel Laidig) is statically linked. Full license + citation:
[swift/Sources/VQFC/LICENSE-VQF.txt](swift/Sources/VQFC/LICENSE-VQF.txt).

## How it works

1. `braw_helper --gyro <file>` dumps the embedded IMU samples (gyro + accel,
   ~960 Hz on the 12K URSA Cine Immersive).
2. `vqf.offlineVQF` fuses them into drift-corrected orientation quaternions,
   one per IMU sample.
3. Each video frame takes the IMU quaternion nearest its mid-frame timestamp.
4. A reference trajectory is computed — either the first frame (camera lock)
   or a velocity-dampened bidirectional NLERP smoothing pass (GoPro-style).
5. Per-frame correction `q_corr = q_raw⁻¹ · q_ref`, converted to a 3×3
   matrix and remapped into the camera's axis convention (IMU → sensor:
   negate Y, empirically verified).
6. Each correction matrix is decomposed into ZYX Euler angles (Tilt, Pan,
   Roll) — matching `PanoMap`'s default rotation order.
7. The three per-frame angle series become three `BezierSpline` blocks with
   dense Linear keyframes. They drive `Rotate.X/Y/Z` on the PanoMap node.

Output Lua structure:

```lua
{
    Tools = ordered() {
        PanoMap1 = PanoMap { Inputs = { From = …, To = …,
            ["Rotate.X"] = Input { SourceOp = "PanoMap1RotateX", Source = "Value" },
            ["Rotate.Y"] = Input { SourceOp = "PanoMap1RotateY", Source = "Value" },
            ["Rotate.Z"] = Input { SourceOp = "PanoMap1RotateZ", Source = "Value" },
        } },
        PanoMap1RotateX = BezierSpline { KeyFrames = { [0]={…}, [1]={…}, … } },
        PanoMap1RotateY = BezierSpline { … },
        PanoMap1RotateZ = BezierSpline { … },
    },
    ActiveTool = "PanoMap1"
}
```

## Why paste-into-Fusion instead of patching the DRT

The earlier approach wrote the keyframes straight into a `.drt` timeline's
`<CompositionBA>` blob. It kept round-tripping byte-perfectly, but Resolve
silently dropped the PanoMap nodes whenever the inner tools-Lua bytes
differed from the original — even a single-character change. We never
located the validator (it's not any obvious hash of tools_lua, the BA
header's keyframe count, the clip's `<Body>` version blobs, or the
composition's `DbId`). Pasting the node inside Fusion itself bypasses that
validation entirely and leaves no room for format surprises.

## Limitations

- **macOS + Apple Silicon only** — `braw_helper` is an arm64 binary against
  the BMD SDK. Intel Macs and Windows would need a rebuild.
- **Stereo**: the output has one PanoMap. For the second eye, paste the
  same setting into the right-eye stream (the rotations apply identically
  per clip, not per eye).
- **Frame-rate assumption**: timeline fps is assumed to match source fps.
  For mismatched-fps projects with speed changes, the per-frame mapping
  would need to account for retiming — not currently handled.
- **Non-BMD Cine Immersive sources** (DJI OSV, etc.) have their own gyro
  path in the parent DualFish app and aren't wired through here.
