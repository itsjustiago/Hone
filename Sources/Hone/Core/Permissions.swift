import ApplicationServices
import CoreGraphics
import AppKit

/// Wraps the macOS Accessibility (AX) trust check used by every low-level module.
///
/// Intercepting scroll events with a `CGEventTap` and reading window layout with
/// the AX API both require the app to be trusted in
/// System Settings ▸ Privacy & Security ▸ Accessibility.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    /// Whether the app is currently trusted for Accessibility.
    private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()

    /// Whether the app can capture the screen (needed for window thumbnails).
    private(set) var isScreenRecordingTrusted: Bool = CGPreflightScreenCaptureAccess()

    private var pollTimer: Timer?

    private init() {}

    /// Re-reads the current trust state (cheap; call after returning from Settings).
    func refresh() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        isScreenRecordingTrusted = CGPreflightScreenCaptureAccess()
    }

    /// Prompts for Screen Recording access (first call shows the system dialog).
    @discardableResult
    func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        isScreenRecordingTrusted = granted
        return granted
    }

    /// Prompts the user for Accessibility access. macOS shows its system dialog
    /// with a shortcut to the relevant Settings pane. Returns the current state.
    @discardableResult
    func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        isAccessibilityTrusted = trusted
        if !trusted { startPolling() }
        return trusted
    }

    /// Opens the Accessibility settings pane directly.
    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        startPolling()
    }

    /// The system dialog grants asynchronously, so poll until the state flips,
    /// then notify observers. Stops itself once trusted.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = AXIsProcessTrusted()
                if now != self.isAccessibilityTrusted {
                    self.isAccessibilityTrusted = now
                }
                if now {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }
}
