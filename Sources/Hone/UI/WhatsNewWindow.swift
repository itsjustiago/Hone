import SwiftUI
import AppKit
import HoneDesign
import SleepyKit
import StatsKit

/// The "Novidades" window: shown once after an update, with what changed and a
/// switch for each new tool or option. Same black-and-mascots look as the
/// onboarding.
@MainActor
final class WhatsNewController: NSObject {
    private var window: NSWindow?

    /// Called at launch. Records the version as seen and, when there is news the
    /// user hasn't seen, opens the window. `didOnboard` is the value from before
    /// this launch's onboarding: a new install sees the welcome window, not this.
    func showIfNeeded(manager: ModuleManager, didOnboard: Bool) {
        let defaults = UserDefaults.standard
        let current = Updater.currentVersion
        // Testing by hand (HONE_DEBUG_VERSION): the stored key is left alone, both ways.
        let debug = WhatsNew.debugOverride(environment: ProcessInfo.processInfo.environment)
        let stored = debug == nil ? defaults.string(forKey: WhatsNew.lastSeenKey) : nil
        let lastSeen = debug != nil ? debug?.lastSeen : stored

        let pending = WhatsNew.pending(in: WhatsNew.releases, lastSeen: lastSeen,
                                       current: current, didOnboard: didOnboard)
        // Seen as soon as it shows, not when it's closed.
        if debug?.persists ?? true {
            defaults.set(WhatsNew.lastSeenToStore(stored: stored, current: current), forKey: WhatsNew.lastSeenKey)
        }
        guard !pending.isEmpty else { return }
        show(pending, manager: manager)
    }

    private func show(_ releases: [WhatsNewRelease], manager: ModuleManager) {
        if window == nil { build(releases, manager: manager) }
        // Defer and force front — an accessory app won't present a window reliably
        // during launch otherwise.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.center()
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    private func build(_ releases: [WhatsNewRelease], manager: ModuleManager) {
        let hosting = NSHostingView(
            rootView: WhatsNewView(manager: manager, releases: releases, onClose: { [weak self] in self?.window?.close() })
                .blobsFollowPointer())
        // The list is fixed for the life of the window, so its height is too: as tall
        // as the content, up to `WhatsNewContent.maxListHeight` of list and then it scrolls.
        let size = hosting.fittingSize
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WhatsNewContent.width, height: size.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.title = "Novidades"
        // Black like the popover, whatever the system appearance is.
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(VibeColor.canvas)
        w.isReleasedWhenClosed = false
        w.contentView = hosting
        window = w
    }
}

/// The live window: bridges the manager and the Kits' options to `WhatsNewContent`.
struct WhatsNewView: View {
    let manager: ModuleManager
    let releases: [WhatsNewRelease]
    var onClose: () -> Void

    /// The Kits' options aren't observable. This goes up with every switch flipped
    /// here, and when the app comes back to the front (they may have been changed
    /// in Settings meanwhile), so the switches read them again.
    @State private var revision = 0

    var body: some View {
        let _ = revision
        WhatsNewContent(
            releases: releases,
            isOn: { WhatsNewSwitches.isOn($0, manager: manager) },
            setOn: { toggle, on in
                WhatsNewSwitches.set(toggle, on, manager: manager)
                revision += 1
            },
            close: onClose)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            revision += 1
        }
    }
}

/// Reads and writes the state behind each `WhatsNewToggle`, through the same
/// paths as the home and the tools' Settings pages.
@MainActor
enum WhatsNewSwitches {
    static func isOn(_ toggle: WhatsNewToggle, manager: ModuleManager) -> Bool {
        switch toggle {
        case .module(let id): return manager.modules.first { $0.id == id }?.isEnabled ?? false
        case .statsReadouts: return stats(manager)?.toolKit.showsExtraReadouts ?? false
        case .sleepyCountdown: return sleepy(manager)?.toolKit.showsCountdown ?? false
        case .sleepyMouseNudge: return sleepy(manager)?.toolKit.nudgesMouse ?? false
        }
    }

    static func set(_ toggle: WhatsNewToggle, _ on: Bool, manager: ModuleManager) {
        switch toggle {
        case .module(let id):
            if let module = manager.modules.first(where: { $0.id == id }) { manager.setEnabled(on, for: module) }
            return
        case .statsReadouts: stats(manager)?.toolKit.setShowsExtraReadouts(on)
        case .sleepyCountdown: sleepy(manager)?.toolKit.setShowsCountdown(on)
        case .sleepyMouseNudge: sleepy(manager)?.toolKit.setNudgesMouse(on)
        }
        // Turning an app's option on means the app should be on; turning it off leaves the app alone.
        if on, let parentID = toggle.parentModuleID,
           let parent = manager.modules.first(where: { $0.id == parentID }), !parent.isEnabled {
            manager.setEnabled(true, for: parent)
        }
    }

    private static func stats(_ manager: ModuleManager) -> EmbeddedToolModule<StatsTool>? {
        manager.modules.first { $0.id == "stats" } as? EmbeddedToolModule<StatsTool>
    }

    private static func sleepy(_ manager: ModuleManager) -> EmbeddedToolModule<SleepyTool>? {
        manager.modules.first { $0.id == "sleepy" } as? EmbeddedToolModule<SleepyTool>
    }
}

// MARK: - Content

/// Plain values in, closures out, so the preview renderer can draw it offscreen.
/// `releases` are the ones to show, newest first (see `WhatsNew.pending`).
struct WhatsNewContent: View {
    static let width: CGFloat = 460
    /// The list scrolls past this: with the hero and the button around it, the window tops out at 620 pt.
    static let maxListHeight: CGFloat = 394

    let releases: [WhatsNewRelease]
    var isOn: (WhatsNewToggle) -> Bool = { _ in false }
    var setOn: (WhatsNewToggle, Bool) -> Void = { _, _ in }
    var close: () -> Void = {}
    /// Only the preview renders turn it off: they can't draw a `ScrollView`, so they
    /// show the top of the list, as the window opens.
    var scrolls = true

    private var showsVersions: Bool { releases.count > 1 }

    var body: some View {
        VStack(spacing: VibeSpacing.cardGap) {
            hero
            list
            Button(action: close) {
                Text("Fechar").frame(maxWidth: .infinity)
            }
            .buttonStyle(VibeButtonStyle(prominent: true))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        // Clear of the window buttons: the content runs under the title bar.
        .padding(.top, 44)
        .padding(.bottom, 16)
        .frame(width: Self.width)
        .ignoresSafeArea()
        .vibePanelBackground()
    }

    private var hero: some View {
        HStack(spacing: 18) {
            Blob(color: VibePalette.white, mood: .awake, height: 54, glow: true)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text("Novidades")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(VibeColor.text1)
                Text(subtitle)
                    .font(VibeFont.subtitle)
                    .foregroundStyle(VibeColor.text3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .vibeCard()
    }

    private var subtitle: String {
        showsVersions ? "O que mudou desde a última vez." : "O que há de novo no Hone \(releases.first?.version ?? "")."
    }

    /// As tall as its rows, then it scrolls.
    private var list: some View {
        Group {
            if scrolls {
                ScrollView { rows }.scrollBounceBehavior(.basedOnSize)
            } else {
                // Rows at their own height (not squeezed to the frame); the frame cuts the rest.
                rows.fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: Self.maxListHeight, alignment: .top)
        .clipped()
        .vibeCard(padding: 8)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(releases) { release in
                if showsVersions { VibeSectionLabel("Versão \(release.version)") }
                ForEach(release.items) { ItemRow(item: $0, isOn: isOn, setOn: setOn) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One piece of news: its symbol in a circle, what it is, and — when there is
/// something to turn on — the switch.
private struct ItemRow: View {
    let item: WhatsNewItem
    let isOn: (WhatsNewToggle) -> Bool
    let setOn: (WhatsNewToggle, Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 24, height: 24)
                .background(item.tint.vibeMix(over: VibeColor.inset, amount: 0.16), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(VibeFont.action)
                    .foregroundStyle(VibeColor.text1)
                Text(item.detail)
                    .font(VibeFont.caption)
                    .foregroundStyle(VibeColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let toggle = item.toggle {
                Toggle("Ligar \(item.title)", isOn: Binding(
                    get: { isOn(toggle) },
                    set: { setOn(toggle, $0) }))
                    .toggleStyle(VibeToggleStyle(tint: item.tint))
                    .accessibilityLabel("Ligar \(item.title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: VibeMetrics.rowHeight, alignment: .leading)
        .background(VibeColor.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(VibeColor.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
