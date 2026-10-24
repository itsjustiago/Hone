// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hone",
    platforms: [.macOS(.v14)],
    products: [
        // Loaded into /usr/bin/perl at runtime (never linked into Hone): the Island's
        // "now playing" source. build.sh copies it into Hone.app/Contents/Frameworks.
        .library(name: "HoneNowPlaying", type: .dynamic, targets: ["HoneNowPlaying"])
    ],
    targets: [
        .executableTarget(
            name: "Hone",
            dependencies: ["HoneDesign", "SleepyKit", "ClippyKit", "ScreenlyKit", "StatsKit", "LidFoldKit", "SoundlyKit"],
            path: "Sources/Hone",
            swiftSettings: [
                // The system-level modules (event taps, AX API, C callbacks) are
                // inherently main-thread / single-owner. Swift 5 language mode keeps
                // that code readable without fighting strict-concurrency diagnostics.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Shared visual language (tokens, Blob mascot, controls) for Hone and
        // the Kits. Pure SwiftUI so `ImageRenderer` can draw every piece of it.
        .target(
            name: "HoneDesign",
            path: "Sources/HoneDesign",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Former standalone menu-bar apps, embedded as tools. Each lives in its
        // own module so their identically named types (DesignKit, MenuPanel,
        // SettingsSection…) never collide; only a small `…Tool` facade is public.
        .target(
            name: "SleepyKit",
            dependencies: ["HoneDesign"],
            path: "Sources/SleepyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ClippyKit",
            dependencies: ["HoneDesign"],
            path: "Sources/ClippyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ScreenlyKit",
            dependencies: ["HoneDesign"],
            path: "Sources/ScreenlyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "StatsKit",
            dependencies: ["HoneDesign"],
            path: "Sources/StatsKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Soundly: per-app volume through Core Audio process taps (macOS 14.2+).
        // System frameworks only — no virtual driver, no kext.
        .target(
            name: "SoundlyKit",
            dependencies: ["HoneDesign"],
            path: "Sources/SoundlyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Lid-angle sensor plus the pure fold maths ("iPhone Duo" screen effect).
        // System frameworks only: it depends on no Kit, never touches brightness,
        // display sleep or power assertions (Sleepy owns those).
        .target(
            name: "LidFoldKit",
            path: "Sources/LidFoldKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MediaRemote adapter (Objective-C) for the Island. Since macOS 15.4 MediaRemote
        // answers only Apple-entitled processes, so the Hone loads this into the
        // platform binary /usr/bin/perl and talks to it over stdin/stdout.
        .target(
            name: "HoneNowPlaying",
            path: "Sources/HoneNowPlaying",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        // Hone's own pure logic (Quit on Close's decisions). The Kits have their own.
        .testTarget(
            name: "HoneTests",
            dependencies: ["Hone"],
            path: "Tests/HoneTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LidFoldKitTests",
            dependencies: ["LidFoldKit"],
            path: "Tests/LidFoldKitTests",
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
        ),
        .testTarget(
            name: "SoundlyKitTests",
            dependencies: ["SoundlyKit"],
            path: "Tests/SoundlyKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StatsKitTests",
            dependencies: ["StatsKit"],
            path: "Tests/StatsKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
