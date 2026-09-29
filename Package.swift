// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Hone",
            dependencies: ["SleepyKit", "ClippyKit", "ScreenlyKit"],
            path: "Sources/Hone",
            swiftSettings: [
                // The system-level modules (event taps, AX API, C callbacks) are
                // inherently main-thread / single-owner. Swift 5 language mode keeps
                // that code readable without fighting strict-concurrency diagnostics.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Former standalone menu-bar apps, embedded as tools. Each lives in its
        // own module so their identically named types (DesignKit, MenuPanel,
        // SettingsSection…) never collide; only a small `…Tool` facade is public.
        .target(
            name: "SleepyKit",
            path: "Sources/SleepyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ClippyKit",
            path: "Sources/ClippyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ScreenlyKit",
            path: "Sources/ScreenlyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ScreenlyKitTests",
            dependencies: ["ScreenlyKit"],
            path: "Tests/ScreenlyKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SleepyKitTests",
            dependencies: ["SleepyKit"],
            path: "Tests/SleepyKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
