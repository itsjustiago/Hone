import AppKit
import SwiftUI

/// The switcher's live state, observed by `AltTabView`. The list is fixed for a
/// session; only `index` moves as the user cycles, so the view just re-highlights.
@MainActor
@Observable
final class AltTabSelection {
    var entries: [AltTabEntry] = []
    var index: Int = 0
}

/// Wires the hot-key tap to the window list, the overlay and window focusing.
///
/// Ordering mirrors the other low-level tools: the tap (which needs Accessibility)
/// is what gates everything — if it can't start, nothing is shown and no keys are
/// captured, so the switcher never half-works.
@MainActor
final class AltTabController {
    private let tap = AltTabHotKeyTap()
    private let overlay = AltTabOverlay()
    private let selection = AltTabSelection()

    private var isOpen = false
    private var settings: AltTabSettings?
    private var tint: Color = .teal
    /// Drives live-preview refreshing while the switcher is open (nil when static).
    private var liveTimer: Timer?

    func start(settings: AltTabSettings, tint: Color) {
        self.settings = settings
        self.tint = tint
        tap.modifierFlag = settings.modifier.flag
        tap.onActivate = { [weak self] backward in self?.activate(backward: backward) ?? false }
        tap.onStep = { [weak self] backward in self?.step(backward: backward) }
        tap.onCommit = { [weak self] in self?.commit() }
        tap.onCancel = { [weak self] in self?.cancel() }
        tap.start()
    }

    func stop() {
        cancel()
        tap.stop()
    }

    /// The modifier changed in settings — re-point the tap without a full restart.
    func updateModifier(_ modifier: AltTabModifier) {
        tap.modifierFlag = modifier.flag
    }

    // MARK: - Session

    private func activate(backward: Bool) -> Bool {
        guard let settings else { return false }
        let entries = AltTabWindowLister.allWindows(includeMinimized: settings.includeMinimized)
        // Nothing to switch between — leave keys flowing normally.
        guard entries.count >= 2 else { return false }

        selection.entries = entries
        // Front window is index 0 (where we are now); start on the neighbour so a
        // quick tap-and-release flips to the previously used window.
        selection.index = backward ? entries.count - 1 : 1
        overlay.show(selection: selection, tint: tint,
                     onHover: { [weak self] index in self?.hover(index) },
                     onPick: { [weak self] entry in self?.pick(entry) },
                     onCancel: { [weak self] in self?.cancel() })
        isOpen = true

        // Static previews (the snapshot from the lister) are enough by default;
        // only keep re-capturing when the user asked for a live view.
        if settings.livePreviews && Permissions.shared.isScreenRecordingTrusted {
            startLiveRefresh()
        }
        return true
    }

    /// Re-capture each visible window periodically so its preview stays live. Kept
    /// modest — a handful of windows on a slow tick — since it holds the
    /// screen-recording indicator on the whole time it runs.
    private func startLiveRefresh() {
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshThumbnails() }
        }
    }

    private func refreshThumbnails() {
        guard isOpen else { return }
        var entries = selection.entries
        var changed = false
        for i in entries.indices where !entries[i].window.isMinimized && entries[i].window.id != 0 {
            if let image = WindowEnumerator.thumbnail(for: entries[i].window.id) {
                entries[i].window.thumbnail = image
                changed = true
            }
        }
        if changed { selection.entries = entries }
    }

    /// The mouse moved over a tile — follow it.
    private func hover(_ index: Int) {
        guard isOpen, selection.entries.indices.contains(index) else { return }
        selection.index = index
    }

    /// A tile was clicked — focus it now, even if the modifier is still down. The
    /// tap's modal session is ended too, so the later modifier-release is a no-op.
    private func pick(_ entry: AltTabEntry) {
        guard isOpen else { return }
        closeOverlay()
        tap.endSession()
        WindowFocuser.focus(entry.window)
    }

    private func step(backward: Bool) {
        guard isOpen else { return }
        let n = selection.entries.count
        guard n > 0 else { return }
        selection.index = ((selection.index + (backward ? -1 : 1)) % n + n) % n
    }

    private func commit() {
        guard isOpen else { return }
        let target = selection.entries.indices.contains(selection.index)
            ? selection.entries[selection.index] : nil
        closeOverlay()
        if let target { WindowFocuser.focus(target.window) }
    }

    private func cancel() {
        guard isOpen else { return }
        closeOverlay()
    }

    private func closeOverlay() {
        liveTimer?.invalidate()
        liveTimer = nil
        overlay.hide()
        selection.entries = []
        selection.index = 0
        isOpen = false
    }
}
