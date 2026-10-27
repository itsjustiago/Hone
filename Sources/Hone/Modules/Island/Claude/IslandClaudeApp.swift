import AppKit

/// Bringing a session forward in the Claude app, from a row of the island.
enum IslandClaudeApp {
    static let bundleID = "com.anthropic.claudefordesktop"

    /// What to ask of the system for a session, worked out without touching
    /// anything, so it can be tested without opening the app.
    enum Request: Equatable {
        /// Open the session's link (`ClaudeSession.appURL`) with the app at `app`.
        case open(URL, app: URL)
        /// No link for the session: just bring the app at `app` forward.
        case activate(app: URL)
        /// The app is not installed: nothing to do.
        case none
    }

    /// `app`: where the Claude app is installed, `nil` if it isn't.
    static func request(for session: ClaudeSession, app: URL?) -> Request {
        guard let app else { return .none }
        guard let link = session.appURL else { return .activate(app: app) }
        return .open(link, app: app)
    }

    /// Opens `session` in the Claude app, or only brings the app forward. `false`
    /// when there is no app to ask: nothing happened.
    @MainActor
    @discardableResult
    static func open(_ session: ClaudeSession) -> Bool {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        switch request(for: session, app: app) {
        case let .open(link, app):
            NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration)
        case let .activate(app):
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                running.activate()
            } else {
                NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            }
        case .none:
            return false
        }
        return true
    }
}
