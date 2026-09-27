import CoreGraphics
import AppKit

/// Wraps the macOS **Screen Recording** permission that Screenly needs to grab
/// pixels. Inside Hone the grant belongs to the host process (`screencapture` and
/// ScreenCaptureKit run on its behalf). Nothing here prompts on its own: only a
/// capture or the panel's "Conceder acesso…" button ever calls `request()`.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    /// Whether the app can currently capture the screen.
    @Published private(set) var isTrusted: Bool = CGPreflightScreenCaptureAccess()

    private var pollTimer: Timer?

    private init() {}

    /// Re-reads the current trust state (cheap; call after returning from Settings).
    func refresh() { isTrusted = CGPreflightScreenCaptureAccess() }

    /// Prompts for Screen Recording access (first call shows the system dialog).
    /// macOS grants asynchronously, so we poll until the state flips.
    @discardableResult
    func request() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        isTrusted = granted
        if !granted { startPolling() }
        return granted
    }

    /// Opens the Screen Recording settings pane directly, then watches for the grant.
    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
        startPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = CGPreflightScreenCaptureAccess()
                if now != self.isTrusted { self.isTrusted = now }
                if now {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }
}
