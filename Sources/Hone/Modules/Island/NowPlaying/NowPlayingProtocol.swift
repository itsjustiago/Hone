import Foundation

/// One decoded stdout line of the adapter.
enum NowPlayingUpdate: Equatable {
    /// Nothing is playing.
    case empty
    /// `artwork` is set only when this very line carried it; `merge` keeps the old one.
    case track(NowPlayingTrack)
}

/// The adapter's stdout format: one JSON object per line, UTF-8. Mirrored by the
/// header comment of HoneNowPlaying.m (change both together).
///
///     {"empty":true}
///     {"title":str, "artist":str, "album":str,      each omitted when unknown
///      "duration":sec,                             omitted when unknown or live
///      "elapsed":sec, "elapsedAt":unixSec,         position as of that instant
///      "rate":number, "playing":bool,
///      "pid":int, "bundleID":str, "contentID":str, omitted when unknown
///      "artwork":base64}                           only when the bytes changed
enum NowPlayingProtocol {
    private struct Wire: Decodable {
        var empty: Bool?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var elapsedAt: Double?
        var rate: Double?
        var playing: Bool?
        var pid: Int?
        var bundleID: String?
        var contentID: String?
        var artwork: String?
    }

    /// nil for a line that is not valid or says nothing useful: skipped, not fatal.
    /// `receivedAt` stands in for `elapsedAt` when the adapter sent none.
    static func decode(_ line: Data, receivedAt: Date = Date()) -> NowPlayingUpdate? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: line) else { return nil }
        if wire.empty == true { return .empty }

        let title = wire.title ?? ""
        let artist = wire.artist ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        let playing = wire.playing ?? false
        // A playing track whose rate says 0 would freeze the progress bar; the
        // apps that report it are wrong, so play it at normal speed.
        let reported = wire.rate ?? 0
        let rate = playing && reported <= 0 ? 1 : reported
        let artwork = wire.artwork.flatMap { Data(base64Encoded: $0) }.flatMap { $0.isEmpty ? nil : $0 }

        return .track(NowPlayingTrack(
            id: NowPlayingTrack.makeID(contentID: wire.contentID, title: title, artist: artist),
            title: title,
            artist: artist,
            album: wire.album ?? "",
            duration: wire.duration.flatMap { $0 > 0 ? $0 : nil },
            elapsed: max(0, wire.elapsed ?? 0),
            elapsedSampledAt: wire.elapsedAt.map { Date(timeIntervalSince1970: $0) } ?? receivedAt,
            playbackRate: rate,
            isPlaying: playing,
            bundleID: wire.bundleID.flatMap { $0.isEmpty ? nil : $0 },
            pid: wire.pid.flatMap { Int32(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil },
            artwork: artwork
        ))
    }

    /// The adapter sends the cover only when its bytes change, so the previous one
    /// carries over while it is the same track. A new track starts without a cover
    /// until its own arrives (it is always re-sent for a new track).
    static func merge(_ update: NowPlayingUpdate, into previous: NowPlayingTrack?) -> NowPlayingTrack? {
        switch update {
        case .empty:
            return nil
        case .track(var track):
            if track.artwork == nil, let previous, previous.id == track.id {
                track.artwork = previous.artwork
            }
            return track
        }
    }
}

/// Splits a byte stream into lines. Pipes hand over arbitrary chunks: a line can
/// arrive in pieces, one chunk can hold several, and a multi-byte UTF-8 character
/// can be cut in two. Splitting on the raw newline byte (never inside a UTF-8
/// sequence) and decoding only whole lines makes all three harmless.
struct LineBuffer {
    /// A line longer than this is dropped, not buffered: the adapter's lines carry a
    /// base64 cover (a few hundred KB), so this is generous, but it stops a runaway
    /// stream from eating memory.
    let maxLineLength: Int
    private var pending = Data()
    /// True while swallowing the rest of an over-long line.
    private var skipping = false

    init(maxLineLength: Int = 16 * 1024 * 1024) {
        self.maxLineLength = maxLineLength
    }

    /// The complete, non-empty lines in `chunk` (newline removed, a trailing "\r" too).
    mutating func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            if skipping {
                skipping = false
            } else {
                var line = pending
                line.append(chunk[start..<newline])
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty, line.count <= maxLineLength { lines.append(line) }
            }
            pending = Data()
            start = newline + 1
        }
        if !skipping {
            pending.append(chunk[start...])
            if pending.count > maxLineLength {
                pending = Data()
                skipping = true
            }
        }
        return lines
    }
}

/// stdout chunks in, updates out. One instance per adapter process, fed from a
/// single queue (the pipe's readability handler).
final class NowPlayingStreamDecoder {
    private var buffer = LineBuffer()

    func feed(_ chunk: Data, receivedAt: Date = Date()) -> [NowPlayingUpdate] {
        buffer.append(chunk).compactMap { NowPlayingProtocol.decode($0, receivedAt: receivedAt) }
    }
}
