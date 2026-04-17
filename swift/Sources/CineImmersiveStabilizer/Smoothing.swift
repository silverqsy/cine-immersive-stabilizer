// Velocity-dampened bidirectional NLERP smoothing — same algorithm as
// braw_stab.py._smooth_quats_velocity_dampened. Takes a per-frame raw
// quaternion trajectory, produces a per-frame smoothed reference
// trajectory.
//
// Higher angular velocity → shorter tau → less smoothing (responsive to
// intentional motion). Lower velocity → longer tau → more smoothing
// (cancels shake while the camera is holding).

import Foundation

enum Smoothing {

    static func velocityDampened(
        quats: [Quat],
        fps: Double,
        smoothMs: Double,
        fastMs: Double,
        maxVelocityDegPerSec: Double,
        maxCorrectionDeg: Double,
        responsiveness: Double
    ) -> [Quat] {
        let N = quats.count
        if N < 2 { return quats }
        let dt = 1.0 / fps

        // Per-frame angular velocity (deg/s)
        var velocities = [Double](repeating: 0, count: N)
        for i in 1..<N {
            var d = abs(Quat.dot(quats[i-1], quats[i]))
            if d > 1 { d = 1 }
            let angle = 2.0 * acos(d)
            velocities[i] = angle * 180.0 / .pi / dt
        }
        // Smooth velocities with 200 ms bidirectional exponential
        let velAlpha = min(1.0, dt / 0.2)
        let velDecay = 1.0 - velAlpha
        for i in 1..<N {
            velocities[i] = velocities[i-1] * velDecay + velocities[i] * velAlpha
        }
        for i in stride(from: N-2, through: 0, by: -1) {
            velocities[i] = velocities[i+1] * velDecay + velocities[i] * velAlpha
        }

        // Per-frame alpha
        let tauSmooth = smoothMs / 1000.0
        let tauFast   = fastMs   / 1000.0
        let respPower = max(0.1, responsiveness)
        var alphas = [Double](repeating: 0, count: N)
        for i in 0..<N {
            let velLinear: Double = maxVelocityDegPerSec > 0
                ? min(1.0, max(0.0, velocities[i] / maxVelocityDegPerSec))
                : 0
            let velRatio = pow(velLinear, respPower)
            let tau = tauSmooth * (1.0 - velRatio) + tauFast * velRatio
            alphas[i] = max(0.0, min(1.0, dt / (tau + dt)))
        }

        // Forward + backward NLERP passes
        var fwd = quats
        for i in 1..<N {
            fwd[i] = Quat.nlerp(fwd[i-1], quats[i], alphas[i])
        }
        var bwd = quats
        for i in stride(from: N-2, through: 0, by: -1) {
            bwd[i] = Quat.nlerp(bwd[i+1], quats[i], alphas[i])
        }

        // Average fwd + bwd (NLERP at t=0.5)
        var smoothed = [Quat](repeating: .identity, count: N)
        for i in 0..<N { smoothed[i] = Quat.nlerp(fwd[i], bwd[i], 0.5) }

        // Soft-elastic max-correction cap
        if maxCorrectionDeg > 0 {
            let maxCorrRad = maxCorrectionDeg * .pi / 180
            for i in 0..<N {
                var dot = Quat.dot(quats[i], smoothed[i])
                if dot < 0 { smoothed[i] = -smoothed[i]; dot = -dot }
                if dot > 1 { dot = 1 }
                let angle = 2.0 * acos(dot)
                if angle > maxCorrRad {
                    let soft = maxCorrRad * (1.0 + log(angle / maxCorrRad))
                    let t = min(soft / angle, 1.0)
                    smoothed[i] = Quat.nlerp(quats[i], smoothed[i], t)
                }
            }
        }

        return smoothed.map { $0.normalized() }
    }
}
