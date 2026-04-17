// Cine Immersive Stabilizer — SwiftUI app entry point.
//
// Window-only app (no menu bar extras). The real work lives in
// `ContentView` and the stabilization helpers it invokes.
//
// Hidden developer hook: if invoked as `… --cli <braw>` we run the
// pipeline headless and dump the first/last keyframes to stdout, then
// exit. Handy for regression tests against the reference Python
// implementation.

import SwiftUI
import Foundation

@main
struct CineImmersiveStabilizerApp: App {
    init() {
        let args = CommandLine.arguments
        if args.count >= 3 && args[1] == "--cli" {
            runCLI(braw: URL(fileURLWithPath: args[2]))
            exit(0)
        }
    }

    var body: some Scene {
        Window("Cine Immersive Stabilizer — by Siyang Qi", id: "main") {
            ContentView()
                .frame(minWidth: 640, idealWidth: 780,
                        minHeight: 720, idealHeight: 860)
        }
        .windowResizability(.contentSize)
    }
}

private func runCLI(braw: URL) {
    let settings = StabSettings(smoothMs: 1000, maxCorrDeg: 15,
                                 responsiveness: 1.0, horizonLock: false)
    do {
        let r = try Stabilizer.process(braw: braw, settings: settings) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        let kfs = r.keyframes
        print("SWIFT first 3 frames (tilt, pan, roll):")
        for i in 0..<min(3, kfs.tilt.count) {
            print(String(format: "  [%d] %+.6f, %+.6f, %+.6f",
                          kfs.tilt[i].0, kfs.tilt[i].1, kfs.pan[i].1, kfs.roll[i].1))
        }
        let n = kfs.tilt.count
        print("SWIFT last 2 frames:")
        for i in max(0, n-2)..<n {
            print(String(format: "  [%d] %+.6f, %+.6f, %+.6f",
                          kfs.tilt[i].0, kfs.tilt[i].1, kfs.pan[i].1, kfs.roll[i].1))
        }
    } catch {
        FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
        exit(1)
    }
}
