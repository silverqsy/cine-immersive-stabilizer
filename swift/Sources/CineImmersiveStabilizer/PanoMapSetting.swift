// Emit a Fusion .setting file (paste-or-import Lua) containing one
// PanoMap node whose Rotate.X/Y/Z are driven by three freshly-keyed
// BezierSplines.
//
// Format is single-line per BezierSpline, with LH/RH handles at 1/3 and
// 2/3 of each segment — matches Resolve's own export shape.

import Foundation

enum PanoMapSetting {

    static func build(keyframes: StabKeyframes, name: String = "PanoMap1") -> String {
        let sx = splineBlock(name: "\(name)RotateX", kfs: keyframes.tilt)
        let sy = splineBlock(name: "\(name)RotateY", kfs: keyframes.pan)
        let sz = splineBlock(name: "\(name)RotateZ", kfs: keyframes.roll)

        let panomapInputs = """
        From = Input { Value = FuID { "Immersive" }, }, \
        Rotation = Input { Value = 1, }, \
        ["Rotate.X"] = Input { SourceOp = "\(name)RotateX", Source = "Value", }, \
        ["Rotate.Y"] = Input { SourceOp = "\(name)RotateY", Source = "Value", }, \
        ["Rotate.Z"] = Input { SourceOp = "\(name)RotateZ", Source = "Value", }, \
        To = Input { Value = FuID { "Immersive" }, }
        """

        let panomap = """
        \(name) = PanoMap { Inputs = { \(panomapInputs) }, \
        ViewInfo = OperatorInfo { Pos = { 0, 0 } }, Version = 1 }
        """

        return """
        {
        \tTools = ordered() {
        \t\t\(panomap),
        \t\t\(sx),
        \t\t\(sy),
        \t\t\(sz)
        \t},
        \tActiveTool = "\(name)"
        }

        """
    }

    private static func splineBlock(name: String, kfs: [(Int, Double)]) -> String {
        let N = kfs.count
        var parts = [String]()
        parts.reserveCapacity(N)
        for i in 0..<N {
            let (frame, value) = kfs[i]
            var kfParts = [fmt(value)]
            if i > 0 {
                let (pf, pv) = kfs[i - 1]
                let lhF = Double(frame) - (Double(frame) - Double(pf)) / 3.0
                let lhV = value - (value - pv) / 3.0
                kfParts.append("LH = { \(fmt(lhF)), \(fmt(lhV)) }")
            }
            if i < N - 1 {
                let (nf, nv) = kfs[i + 1]
                let rhF = Double(frame) + (Double(nf) - Double(frame)) / 3.0
                let rhV = value + (nv - value) / 3.0
                kfParts.append("RH = { \(fmt(rhF)), \(fmt(rhV)) }")
            }
            kfParts.append("Flags = { Linear = true }")
            parts.append("[\(frame)] = { \(kfParts.joined(separator: ", ")) }")
        }

        let header = "SplineColor = { Red = 240, Green = 10, Blue = 66 }, NameSet = true, "
        let body = "KeyFrames = { " + parts.joined(separator: ", ") + " }"
        return "\(name) = BezierSpline { \(header)\(body) }"
    }

    /// Match Python's `:.15g` formatting: up to 15 significant digits, no
    /// scientific notation for normal values, trailing zeros stripped.
    private static func fmt(_ x: Double) -> String {
        if x == 0 { return "0" }
        if !x.isFinite { return x.description }
        var s = String(format: "%.15g", x)
        // Strip trailing zero noise, e.g. "1.0" → "1"
        if s.contains(".") && !s.contains("e") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
