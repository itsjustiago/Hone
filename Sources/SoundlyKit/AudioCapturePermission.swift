// Adapted from insidegui/AudioCap (BSD-2-Clause), `AudioRecordingPermission.swift`:
// the TCC SPI lookup and its result codes. See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

/// The "System Audio Recording" (`kTCCServiceAudioCapture`) permission that
/// process taps need. macOS has no public API to read or request it, so this
/// uses the TCC framework's `TCCAccessPreflight` / `TCCAccessRequest`, looked up
/// at run time (the approach of insidegui/AudioCap). If the symbols ever go
/// away, `isAvailable` is false: the state stays `.unknown` and the system asks
/// by itself the first time a tap is read.
///
/// Asking *before* the first tap keeps the order sane: no tap is built that the
/// system may refuse to feed — with `mutedWhenTapped`, an unfed tap could mean
/// the app going silent while the prompt waits for an answer.
enum AudioCapturePermission {
    private static let service = "kTCCServiceAudioCapture" as CFString

    static var isAvailable: Bool { preflightFunction != nil && requestFunction != nil }

    /// Reads the state without ever prompting.
    static func current() -> SoundlyPermission {
        guard let preflightFunction else { return .unknown }
        switch preflightFunction(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user was never asked (otherwise answers at
    /// once). `completion` runs on the main queue. Returns `false` when it can't ask.
    @discardableResult
    static func request(_ completion: @escaping (Bool) -> Void) -> Bool {
        guard let requestFunction else { return false }
        requestFunction(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        return true
    }

    /// Privacy & Security › Screen & System Audio Recording, where the audio-only
    /// permission is listed on recent macOS versions.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    // MARK: TCC SPI

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFunction: PreflightFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestFunction: RequestFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()
}
