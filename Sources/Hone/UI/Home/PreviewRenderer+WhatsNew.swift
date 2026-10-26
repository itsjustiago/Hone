import SwiftUI
import HoneDesign

extension PreviewRenderer {
    /// Renders of the "Novidades" window, from the real list of releases and
    /// switches in mixed states. Each is a case of `WhatsNew.pending`.
    static var whatsNewPages: [(String, AnyView)] {
        func page(lastSeen: String?, current: String, on: Set<WhatsNewToggle>) -> AnyView {
            let releases = WhatsNew.pending(in: WhatsNew.releases, lastSeen: lastSeen, current: current,
                                            didOnboard: true)
            return AnyView(WhatsNewContent(releases: releases, isOn: { on.contains($0) }, scrolls: false))
        }
        return [
            // The usual case: one release, nothing to switch.
            ("novidades-atual", page(lastSeen: "0.8.1", current: "0.9.0", on: [.module("island")])),
            // One release with a switch on every row.
            ("novidades", page(lastSeen: "0.6.0", current: "0.7.0",
                               on: [.module("windowsShortcuts"), .sleepyMouseNudge])),
            // Every release at once: a section per version and a scrolling list.
            ("novidades-todas", page(lastSeen: nil, current: "0.9.0",
                                     on: [.module("soundly"), .statsReadouts, .sleepyCountdown])),
        ]
    }
}
