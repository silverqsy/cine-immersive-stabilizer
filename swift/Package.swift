// swift-tools-version:5.9
// Cine Immersive Stabilizer — Swift/SwiftUI build.
//
// Two targets:
//   VQFC  — C++ library (VQF gyro/accel fusion), exposed to Swift via a
//           C-ABI shim so we don't need to enable the experimental Swift
//           C++ interop.
//   CineImmersiveStabilizer — Swift executable (SwiftUI app).

import PackageDescription

let package = Package(
    name: "CineImmersiveStabilizer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CineImmersiveStabilizer", targets: ["CineImmersiveStabilizer"]),
    ],
    targets: [
        .target(
            name: "VQFC",
            path: "Sources/VQFC",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-O3", "-std=c++17"]),
            ]
        ),
        .executableTarget(
            name: "CineImmersiveStabilizer",
            dependencies: ["VQFC"],
            path: "Sources/CineImmersiveStabilizer",
            swiftSettings: [
                .unsafeFlags(["-O"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
