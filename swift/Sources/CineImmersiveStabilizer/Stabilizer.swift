// BRAW IMU → per-frame 3×3 correction matrices → (tilt, pan, roll) degrees.
//
// Mirrors the Python BrawGyroStabilizer. Heavy gyro fusion goes through
// the VQFC C module; smoothing and Euler decomposition are in Swift.

import Foundation
import VQFC

struct StabSettings {
    var smoothMs: Double = 1000
    var maxCorrDeg: Double = 15
    var responsiveness: Double = 1.0
    var horizonLock: Bool = false
    var yawOffset: Double = 0
    var tiltOffset: Double = 0
    var rollOffset: Double = 0
}

struct StabKeyframes {
    let tilt: [(Int, Double)]   // PanoMap Rotate.X
    let pan:  [(Int, Double)]   // PanoMap Rotate.Y
    let roll: [(Int, Double)]   // PanoMap Rotate.Z
}

struct StabResult {
    let info: BrawInfo
    let keyframes: StabKeyframes
}

enum Stabilizer {

    static func process(braw: URL, settings: StabSettings,
                         log: (String) -> Void) throws -> StabResult {
        log("▸ \(braw.lastPathComponent)")

        let info = try BrawHelper.info(for: braw)
        log(String(format: "  %@, %d frames @ %.2f fps",
                    info.cameraModel, info.frameCount, info.frameRate))

        log(String(format: "  Extracting gyro … (%d samples @ %.0f Hz)",
                    info.gyroSampleCount, info.gyroSampleRate))
        let imu = try BrawHelper.gyroStream(for: braw)

        log("  Running VQF fusion + stabilization …")
        let quats = try runVQF(imu: imu)
        let midQuats = mapPerFrame(
            quats: quats, imu: imu, fps: info.frameRate, frameCount: info.frameCount)

        let angles = computeCorrections(
            midQuats: midQuats, settings: settings, fps: info.frameRate)

        var tilt: [(Int, Double)] = []
        var pan:  [(Int, Double)] = []
        var roll: [(Int, Double)] = []
        tilt.reserveCapacity(angles.count)
        pan.reserveCapacity(angles.count)
        roll.reserveCapacity(angles.count)
        for (i, a) in angles.enumerated() {
            tilt.append((i, a.tilt + settings.tiltOffset))
            pan .append((i, a.pan  + settings.yawOffset))
            roll.append((i, a.roll + settings.rollOffset))
        }

        if !angles.isEmpty {
            let t = angles.map(\.tilt), p = angles.map(\.pan), r = angles.map(\.roll)
            log(String(format:
                "  %d keyframes — Tilt %+.2f..%+.2f°, Pan %+.2f..%+.2f°, Roll %+.2f..%+.2f°",
                angles.count, t.min()!, t.max()!,
                p.min()!, p.max()!, r.min()!, r.max()!))
        }

        return StabResult(info: info,
                           keyframes: .init(tilt: tilt, pan: pan, roll: roll))
    }

    // ── VQF bridge ────────────────────────────────────────────────

    private static func runVQF(imu: IMUStream) throws -> [Float] {
        let N = imu.sampleCount
        var gyr = [Float](repeating: 0, count: N * 3)
        var acc = [Float](repeating: 0, count: N * 3)
        for i in 0..<N {
            gyr[i*3    ] = imu.data[i*6    ]
            gyr[i*3 + 1] = imu.data[i*6 + 1]
            gyr[i*3 + 2] = imu.data[i*6 + 2]
            acc[i*3    ] = imu.data[i*6 + 3]
            acc[i*3 + 1] = imu.data[i*6 + 4]
            acc[i*3 + 2] = imu.data[i*6 + 5]
        }
        let ts = Float(1.0 / imu.sampleRate)
        var out = [Float](repeating: 0, count: N * 4)
        let rc = gyr.withUnsafeBufferPointer { g in
            acc.withUnsafeBufferPointer { a in
                out.withUnsafeMutableBufferPointer { o in
                    vqfc_offline_6d(g.baseAddress, a.baseAddress, N, ts, o.baseAddress)
                }
            }
        }
        if rc != 0 {
            throw NSError(domain: "VQFC", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "VQF failed (rc=\(rc))"])
        }
        return out
    }

    // ── Per-frame sampling ────────────────────────────────────────

    private static func mapPerFrame(
        quats: [Float], imu: IMUStream, fps: Double, frameCount: Int
    ) -> [Quat] {
        let frameDur = 1.0 / fps
        var result = [Quat]()
        result.reserveCapacity(frameCount)
        for fi in 0..<frameCount {
            let tMid = (Double(fi) + 0.5) * frameDur
            var idx = Int((tMid * imu.sampleRate).rounded())
            idx = max(0, min(imu.sampleCount - 1, idx))
            let b = idx * 4
            result.append(Quat(
                w: Double(quats[b]),
                x: Double(quats[b + 1]),
                y: Double(quats[b + 2]),
                z: Double(quats[b + 3])))
        }
        return result
    }

    // ── Stabilization pipeline ────────────────────────────────────

    struct FrameAngles { let tilt, pan, roll: Double }

    /// IMU-to-camera axis convention: negate Y only. Empirically verified
    /// in the parent DualFish app. As a similarity transform on rotations,
    /// this flips the sign of the (0,1), (1,0), (1,2), (2,1) entries.
    private static let cameraAxisDiag: (Double, Double, Double) = (1, -1, 1)

    private static func computeCorrections(
        midQuats: [Quat], settings: StabSettings, fps: Double
    ) -> [FrameAngles] {
        let N = midQuats.count
        if N == 0 { return [] }

        // Normalize and hemisphere-align
        var Q = midQuats.map { $0.normalized() }
        for i in 1..<N where Quat.dot(Q[i], Q[i-1]) < 0 {
            Q[i] = -Q[i]
        }

        // Reference trajectory (or camera lock = first frame forever)
        let Qref: [Quat]
        if settings.smoothMs > 0 && N > 1 {
            Qref = Smoothing.velocityDampened(
                quats: Q, fps: fps,
                smoothMs: settings.smoothMs, fastMs: 50,
                maxVelocityDegPerSec: 200,
                maxCorrectionDeg: settings.maxCorrDeg,
                responsiveness: settings.responsiveness)
        } else {
            Qref = Array(repeating: Q[0], count: N)
        }

        var result = [FrameAngles]()
        result.reserveCapacity(N)

        for i in 0..<N {
            // Correction: q_corr = q⁻¹ · q_ref
            let qCorr = Q[i].conjugate() * Qref[i]
            var R = qCorr.matrix.conjugatedByDiagonal(Self.cameraAxisDiag)

            if settings.horizonLock {
                // De-roll so world-down stays vertical in output.
                let Rraw = Q[i].matrix.conjugatedByDiagonal(Self.cameraAxisDiag)
                let gCam = Rraw.transposeTimes((0, 0, -1))
                let gOut = R.transposeTimes(gCam)
                let rollAng = atan2(gOut.0, -gOut.1)
                R = R.timesRotZ(rollAng)
            }

            // ZYX Euler decomposition.
            // Pan = -arcsin(R[2,0]), Tilt = atan2(R[2,1], R[2,2]),
            // Roll-raw = atan2(R[1,0], R[0,0]). Roll is negated to match
            // PanoMap's convention (empirically verified).
            let r20 = max(-1.0, min(1.0, R[2, 0]))
            let pan  = -asin(r20) * 180.0 / .pi
            let tilt = atan2(R[2, 1], R[2, 2]) * 180.0 / .pi
            let roll = atan2(R[1, 0], R[0, 0]) * 180.0 / .pi
            result.append(.init(tilt: tilt, pan: pan, roll: -roll))
        }
        return result
    }
}
