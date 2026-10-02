import SwiftUI
import HoneDesign
import ClippyKit
import ScreenlyKit
import SleepyKit
import StatsKit

extension PreviewRenderer {
    /// Renders of the embedded tools' panels (Clippy, Screenly, Sleepy, Stats)
    /// under the popover's real top bar, from the Kits' own fake data.
    static var kitPages: [(String, AnyView)] {
        [
            ("kit-clippy", shell("clippy", ClippyPreview.panel())),
            ("kit-clippy-alert", shell("clippy", ClippyPreview.panel(hasAccessibility: false))),
            ("kit-screenly", shell("screenly", ScreenlyPreview.panel())),
            ("kit-screenly-alert", shell("screenly", ScreenlyPreview.panel(hasScreenRecording: false))),
            ("kit-sleepy-on", shell("sleepy", SleepyPreview.panel(isActive: true, passwordlessInstalled: false))),
            ("kit-sleepy-off", shell("sleepy", SleepyPreview.panel(isActive: false))),
            ("kit-stats-cpu", shell("stats", StatsPreview.panel(.cpu))),
            ("kit-stats-fan", shell("stats", StatsPreview.panel(.fan))),
        ]
    }

    private static func shell(_ selected: String, _ panel: AnyView) -> AnyView {
        let tabs = [HomeTab.home] + [
            HomeTab(id: "clippy", systemImage: "doc.on.clipboard", title: "Clippy"),
            HomeTab(id: "screenly", systemImage: "camera.viewfinder", title: "Screenly"),
            HomeTab(id: "sleepy", systemImage: "moon.zzz", title: "Sleepy"),
            HomeTab(id: "stats", systemImage: "cpu", title: "Stats"),
        ]
        return AnyView(PopoverShell(tabs: tabs, selectedTab: selected) { panel })
    }
}
