// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Hone",
            path: "Sources/Hone",
            swiftSettings: [
                // The system-level modules (event taps, AX API, C callbacks) are
                // inherently main-thread / single-owner. Swift 5 language mode keeps
                // that code readable without fighting strict-concurrency diagnostics.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
