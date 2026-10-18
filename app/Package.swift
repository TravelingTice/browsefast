// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowseFast",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BrowseFast", targets: ["BrowseFast"]),
        .library(name: "BrowseFastUI", targets: ["BrowseFastUI"]),
    ],
    targets: [
        // Views live in a library so Xcode previews work; SwiftPM executables can't enable ENABLE_DEBUG_DYLIB.
        .target(
            name: "BrowseFastUI",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BrowseFast",
            dependencies: ["BrowseFastUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
