import Foundation

/// Soundly (per-app volume, like SoundSource) packaged as a tool a host app
/// (Hone) can embed. This is the audio engine only: the menu-bar icon, panel and
/// settings come with the UI, and the host decides where they are shown.
///
/// The levels live in the `com.tiagof.hone.soundly` defaults domain, per bundle
/// id, so an app at 40 % is at 40 % again the next time it plays.
@MainActor
public final class SoundlyTool {
    /// The engine the UI binds to (`apps`, `permission`, `setVolume`, `setMuted`…).
    public let mixer: SoundlyMixer

    public var isRunning: Bool { mixer.isRunning }

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: SoundlyStore.suiteName) ?? .standard)
    }

    /// `defaults` is injectable so tests never touch the real preferences.
    init(defaults: UserDefaults) {
        mixer = SoundlyMixer(store: SoundlyStore(defaults: defaults))
    }

    // MARK: - Lifecycle

    /// Starts discovery and applies the saved levels the permission allows.
    /// Never prompts for the permission.
    public func start() {
        mixer.start()
    }

    /// Removes every tap — all apps play untouched again — and stops listening.
    public func stop() {
        mixer.stop()
    }
}
