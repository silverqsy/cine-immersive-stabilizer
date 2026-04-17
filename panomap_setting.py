"""
panomap_setting.py — Emit a Fusion `.setting` file (or paste-text) containing
a single PanoMap node with keyframed Rotate.X/Y/Z inputs.

The output is Lua that Fusion accepts via:
  • File → Paste Settings, or
  • Drag a .setting file into the Fusion view

Because this bypasses the DRT container entirely, there are no hidden
length/hash fields to worry about — Fusion parses the Lua freely.
"""

from __future__ import annotations


def _spline_block(name: str, keyframes: list[tuple[int, float]],
                   color: tuple[int, int, int] = (240, 10, 66)) -> str:
    """Build a BezierSpline Lua block matching Resolve's own output:
    single-line, no trailing commas, LH/RH handles at 1/3 / 2/3 of each
    segment. First keyframe has only RH, last only LH, middle has both.
    """
    r, g, b = color
    N = len(keyframes)
    kf_strs = []
    for i, (frame, value) in enumerate(keyframes):
        parts = [f"{float(value):.15g}"]
        if i > 0:
            pf, pv = keyframes[i - 1]
            lh_f = float(frame) - (float(frame) - float(pf)) / 3.0
            lh_v = float(value) - (float(value) - float(pv)) / 3.0
            parts.append(f"LH = {{ {lh_f:.15g}, {lh_v:.15g} }}")
        if i < N - 1:
            nf, nv = keyframes[i + 1]
            rh_f = float(frame) + (float(nf) - float(frame)) / 3.0
            rh_v = float(value) + (float(nv) - float(value)) / 3.0
            parts.append(f"RH = {{ {rh_f:.15g}, {rh_v:.15g} }}")
        parts.append("Flags = { Linear = true }")
        kf_strs.append(f"[{int(frame)}] = {{ " + ", ".join(parts) + " }")

    header = (f"SplineColor = {{ Red = {r}, Green = {g}, Blue = {b} }}, "
              f"NameSet = true, ")
    body = "KeyFrames = { " + ", ".join(kf_strs) + " }"
    return f"{name} = BezierSpline {{ {header}{body} }}"


def build_panomap_setting(tilt_kfs: list[tuple[int, float]],
                           pan_kfs: list[tuple[int, float]],
                           roll_kfs: list[tuple[int, float]],
                           name: str = "PanoMap1") -> str:
    """Build a Fusion `.setting` file containing one PanoMap node with its
    rotate axes driven by three freshly-keyframed BezierSplines.

    tilt_kfs → Rotate.X, pan_kfs → Rotate.Y, roll_kfs → Rotate.Z
    (matches the ZYX Euler order PanoMap uses by default).

    The returned string is valid Lua that Fusion accepts through either
    File → Paste Settings or as a .setting file dragged into the comp.
    """
    sx = _spline_block(f"{name}RotateX", tilt_kfs)
    sy = _spline_block(f"{name}RotateY", pan_kfs)
    sz = _spline_block(f"{name}RotateZ", roll_kfs)

    panomap_inputs = (
        f'From = Input {{ Value = FuID {{ "Immersive" }}, }}, '
        f'Rotation = Input {{ Value = 1, }}, '
        f'["Rotate.X"] = Input {{ SourceOp = "{name}RotateX", Source = "Value", }}, '
        f'["Rotate.Y"] = Input {{ SourceOp = "{name}RotateY", Source = "Value", }}, '
        f'["Rotate.Z"] = Input {{ SourceOp = "{name}RotateZ", Source = "Value", }}, '
        f'To = Input {{ Value = FuID {{ "Immersive" }}, }}'
    )
    panomap_block = (
        f"{name} = PanoMap {{ Inputs = {{ {panomap_inputs} }}, "
        f"ViewInfo = OperatorInfo {{ Pos = {{ 0, 0 }} }}, Version = 1 }}"
    )

    return (
        "{\n"
        "\tTools = ordered() {\n"
        f"\t\t{panomap_block},\n"
        f"\t\t{sx},\n"
        f"\t\t{sy},\n"
        f"\t\t{sz}\n"
        "\t},\n"
        f'\tActiveTool = "{name}"\n'
        "}\n"
    )


if __name__ == "__main__":
    # Quick sanity preview
    demo = build_panomap_setting(
        tilt_kfs=[(0, 0.0), (30, 5.5), (60, -2.1), (90, 0.0)],
        pan_kfs=[(0, 0.0), (30, -3.3), (60, 1.8), (90, 0.0)],
        roll_kfs=[(0, 0.0), (30, 0.4), (60, -0.7), (90, 0.0)],
    )
    print(demo)
