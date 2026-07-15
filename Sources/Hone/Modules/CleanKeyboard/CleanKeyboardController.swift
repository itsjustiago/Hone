import AppKit
import SwiftUI

/// Orchestrates a keyboard-cleaning session: block the keys, raise the curtain,
/// count down, and lift everything again — via the timer, the on-screen button,
/// or the Esc ×3 gesture, whichever comes first.
///
/// Ordering matters for safety: the event tap is started *before* the overlay is
/// shown, and if the tap can't start (no Accessibility permission) nothing is
/// shown at all — the curtain never lies about the keys being locked.
@MainActor
@Observable
final class CleanKeyboardController {
    private(set) var isEngaged = false

    private let blocker = KeyboardBlocker()
    private let overlay = CleanKeyboardOverlay()
    private var state: CleanKeyboardOverlayState?
    private var timer: Timer?

    /// Lock the keyboard and show the curtain. Returns silently (after prompting
    /// for Accessibility) if the lock can't be established.
    func engage(settings: CleanKeyboardSettings, tint: Color) {
        guard !isEngaged else { return }

        // The tap needs Accessibility. Ask for it rather than faking a lock.
        guard Permissions.shared.isAccessibilityTrusted else {
            Permissions.shared.requestAccessibility()
            return
        }

        blocker.blockFunctionKeys = settings.blockFunctionKeys
        blocker.onUnlockGesture = { [weak self] in self?.disengage() }
        guard blocker.start() else {
            // Trusted but the OS still refused the tap — don't show a fake curtain.
            Permissions.shared.requestAccessibility()
            return
        }

        let total = Int(settings.duration.rounded())
        let state = CleanKeyboardOverlayState(total: total)
        self.state = state
        overlay.show(state: state, tint: tint) { [weak self] in self?.disengage() }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let state = self.state else { return }
                state.remaining -= 1
                if state.remaining <= 0 { self.disengage() }
            }
        }

        isEngaged = true
    }

    /// Restore the keyboard and tear the curtain down. Safe to call repeatedly.
    func disengage() {
        guard isEngaged else { return }
        timer?.invalidate()
        timer = nil
        blocker.stop()
        overlay.hide()
        state = nil
        isEngaged = false
    }
}
