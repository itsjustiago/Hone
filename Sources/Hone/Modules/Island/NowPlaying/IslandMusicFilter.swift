import Foundation

/// The apps the Island listens to. MediaRemote reports whatever holds "now playing":
/// a TikTok or YouTube tab in a browser, a video player, a game. The Island is for
/// music, so only these bundle ids count; everything else is ignored.
enum MusicApps {
    /// Lowercased: `contains` compares case-insensitively.
    static let bundleIDs: Set<String> = [
        "com.apple.music",                  // Music
        "com.apple.itunes",                 // iTunes (older macOS)
        "com.spotify.client",               // Spotify
        "com.deezer.deezer-desktop",        // Deezer
        "com.tidal.desktop",                // TIDAL
        "com.amazon.music",                 // Amazon Music
        "com.github.th-ch.youtube-music",   // YouTube Music (desktop app)
        "com.qobuz.desktop",                // Qobuz
        "com.coppertino.vox",               // VOX
        "com.swinsian.swinsian",            // Swinsian
        "co.brushedtype.doppler-macos",     // Doppler
        "tv.plex.plexamp",                  // Plexamp
    ]

    /// Whether `bundleID` is a music app. Case and surrounding whitespace do not
    /// matter; nil and empty never are.
    static func contains(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !id.isEmpty else { return false }
        return bundleIDs.contains(id)
    }
}

/// Decides what the Island shows out of the raw "now playing". A pure value (no
/// AppKit): whether an app is still running is asked through the closure.
///
/// Known limit: while a video holds "now playing", MediaRemote says nothing about
/// the music app, so the held track stays as it was last reported (position,
/// play/pause) until the music app speaks again, the music app quits, or nothing
/// plays anywhere.
struct IslandMusicFilter {
    /// What the Island shows: the last track a music app reported, or nil.
    private(set) var shown: NowPlayingTrack?
    /// True when the raw "now playing" is the shown music app, so a command would
    /// reach it. False when something else holds it: a command would hit that instead.
    private(set) var ownsNowPlaying = false

    /// Folds in the latest raw "now playing" (`raw`, nil when nothing plays anywhere).
    /// Returns whether `shown` changed.
    @discardableResult
    mutating func update(raw: NowPlayingTrack?, isRunning: (String) -> Bool) -> Bool {
        let before = shown
        if let raw {
            if MusicApps.contains(raw.bundleID) {
                shown = raw
                ownsNowPlaying = true
            } else {
                // Not music (or no way to tell): ignored, the held track stays.
                ownsNowPlaying = false
                if let held = shown?.bundleID, !isRunning(held) { shown = nil }
            }
        } else {
            shown = nil
            ownsNowPlaying = false
        }
        return shown != before
    }
}
