import AppKit
import SwiftUI

/// Orchestrates a keyboard-cleaning session: block the keys and float the little
/// "locked" card, then lift both again — via the card's button or the Esc ×3
/// gesture.
///
/// Ordering matters for safety: the event tap is started *before* the card is
/// shown, and if the tap can't start (no Accessibility permission) nothing is
/// shown at all — the card never claims the keys are locked when they aren't.
@MainActor
@Observable
final class CleanKeyboardController {
    private(set) var isEngaged = false

    private let blocker = KeyboardBlocker()
    private let overlay = CleanKeyboardOverlay()

    /// Lock the keyboard and show the card. Returns silently (after prompting for
    /// Accessibility) if the lock can't be established.
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
            // Trusted but the OS still refused the tap — don't show a fake card.
            Permissions.shared.requestAccessibility()
            return
        }

        overlay.show(tint: tint) { [weak self] in self?.disengage() }
        isEngaged = true
    }

    /// Restore the keyboard and dismiss the card. Safe to call repeatedly.
    func disengage() {
        guard isEngaged else { return }
        blocker.stop()
        overlay.hide()
        isEngaged = false
    }
}
