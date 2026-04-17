// Wrapper for the sibling `braw_helper` binary that ships inside the
// bundle. We only need `--info` (metadata JSON) and `--gyro` (raw IMU
// stream + JSON header on stderr).

import Foundation

enum BrawHelperError: Error, LocalizedError {
    case notFound
    case spawnFailed(String)
    case nonzeroExit(Int32, String)
    case missingHeader(String)
    case malformedHeader(String)
    case noGyroData

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "braw_helper binary not found in app bundle."
        case .spawnFailed(let m): return "braw_helper spawn failed: \(m)"
        case .nonzeroExit(let code, let stderr):
            return "braw_helper exited \(code): \(stderr.prefix(500))"
        case .missingHeader(let stderr):
            return "braw_helper stderr had no JSON header:\n\(stderr.prefix(500))"
        case .malformedHeader(let line):
            return "braw_helper JSON header malformed: \(line)"
        case .noGyroData:
            return "BRAW has no gyro samples."
        }
    }
}

struct BrawInfo {
    let width: Int
    let height: Int
    let frameCount: Int
    let frameRate: Double
    let gyroSampleCount: Int
    let gyroSampleRate: Double
    let cameraModel: String
}

/// gx, gy, gz (rad/s), ax, ay, az (m/s²) per IMU sample.
struct IMUStream {
    let data: [Float]      // row-major, length = 6 * sampleCount
    let sampleCount: Int
    let sampleRate: Double
}

enum BrawHelper {

    /// Resolve the helper binary path. Inside an .app bundle it lives at
    /// Contents/Resources/braw_helper; for dev runs we also honour the
    /// `BRAW_HELPER` env var and scan the executable's and current working
    /// directory.
    static func helperURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["BRAW_HELPER"] {
            let u = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        // Frameworks/braw_helper is where we bundle it (next to the
        // BlackmagicRawAPI.framework so its dladdr-based plugin lookup
        // works). Fall back to a few other spots for dev runs.
        let frameworksDir = Bundle.main.privateFrameworksURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
        let candidates: [URL?] = [
            frameworksDir.appendingPathComponent("braw_helper"),
            Bundle.main.resourceURL?.appendingPathComponent("braw_helper"),
            Bundle.main.executableURL?
                .deletingLastPathComponent().appendingPathComponent("braw_helper"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("braw_helper"),
        ]
        for c in candidates {
            if let u = c, FileManager.default.isExecutableFile(atPath: u.path) {
                return u
            }
        }
        return nil
    }

    /// Run `braw_helper --info <path>` and parse the stdout JSON.
    static func info(for braw: URL) throws -> BrawInfo {
        guard let helper = helperURL() else { throw BrawHelperError.notFound }
        let (stdout, stderr, status) = try runCapture(helper, args: ["--info", braw.path])
        if status != 0 { throw BrawHelperError.nonzeroExit(status, stderr) }
        guard let obj = try JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw BrawHelperError.malformedHeader(String(data: stdout, encoding: .utf8) ?? "")
        }
        return BrawInfo(
            width: obj["width"] as? Int ?? 0,
            height: obj["height"] as? Int ?? 0,
            frameCount: obj["frame_count"] as? Int ?? 0,
            frameRate: obj["frame_rate"] as? Double ?? 0,
            gyroSampleCount: obj["gyro_sample_count"] as? Int ?? 0,
            gyroSampleRate: obj["gyro_sample_rate"] as? Double ?? 0,
            cameraModel: obj["camera_model"] as? String ?? ""
        )
    }

    /// Run `braw_helper --gyro <path>`; JSON header on stderr, packed
    /// float32 [N*6] on stdout.
    static func gyroStream(for braw: URL) throws -> IMUStream {
        guard let helper = helperURL() else { throw BrawHelperError.notFound }
        let (stdout, stderr, status) = try runCapture(helper, args: ["--gyro", braw.path])
        if status != 0 { throw BrawHelperError.nonzeroExit(status, stderr) }
        // stderr may contain an objc class-conflict warning before the JSON
        // header when a separate BlackmagicRawAPI is also on the system.
        // Pick the first line that starts with '{'.
        let headerLine = stderr
            .split(whereSeparator: { $0 == "\n" })
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") })
        guard let headerLine else { throw BrawHelperError.missingHeader(stderr) }
        guard let headerData = String(headerLine).data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let count = obj["sample_count"] as? Int,
              let rate = obj["gyro_sample_rate"] as? Double
        else {
            throw BrawHelperError.malformedHeader(String(headerLine))
        }
        if count == 0 { throw BrawHelperError.noGyroData }
        let expected = count * 6 * MemoryLayout<Float>.size
        if stdout.count < expected {
            throw BrawHelperError.nonzeroExit(
                0, "gyro stream short: got \(stdout.count)B, expected \(expected)B")
        }
        let data = stdout.prefix(expected).withUnsafeBytes { raw -> [Float] in
            let bp = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: bp.baseAddress, count: count * 6))
        }
        return IMUStream(data: data, sampleCount: count, sampleRate: rate)
    }

    // ── subprocess plumbing ───────────────────────────────────────

    private static func runCapture(_ url: URL, args: [String]) throws
        -> (stdout: Data, stderr: String, status: Int32)
    {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() }
        catch { throw BrawHelperError.spawnFailed("\(error)") }

        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (stdout, stderr, p.terminationStatus)
    }
}
