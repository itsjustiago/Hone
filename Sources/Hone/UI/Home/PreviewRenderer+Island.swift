import AppKit
import SwiftUI
import HoneDesign

extension PreviewRenderer {
    /// The island in each presentation, over a fake menu bar and the physical
    /// notch, from fake tracks: with and without a cover, a long title, a live
    /// stream with no length. The covers go through the real decoder, so the tint
    /// is the one the island would pick.
    static var islandPages: [(String, AnyView)] {
        let sunset = IslandArtwork.make(from: fakeCover(
            NSColor(srgbRed: 0.98, green: 0.52, blue: 0.24, alpha: 1),
            NSColor(srgbRed: 0.62, green: 0.16, blue: 0.52, alpha: 1)))
        let night = IslandArtwork.make(from: fakeCover(
            NSColor(srgbRed: 0.10, green: 0.30, blue: 0.55, alpha: 1),
            NSColor(srgbRed: 0.03, green: 0.06, blue: 0.16, alpha: 1)))

        let song = fakeTrack(title: "Midnight City", artist: "M83", duration: 243, elapsed: 83)
        var paused = song
        paused.isPlaying = false
        let long = fakeTrack(
            title: "Não Há Estrela no Céu Que Brilhe Mais do Que o Teu Olhar (Ao Vivo no Coliseu)",
            artist: "Orquestra Ligeira e Coro do Bairro Alto", duration: 4_385, elapsed: 3_725)
        let radio = fakeTrack(title: "Antena 3", artist: "Rádio em direto", duration: nil, elapsed: 0)

        return [
            ("ilha-compacta", stage(.compact, song, sunset, app: "Música")),
            ("ilha-compacta-pausa-sem-capa", stage(.compact, paused, nil, app: "Música")),
            ("ilha-peek", stage(.peek, long, night, app: "Spotify")),
            ("ilha-aberta", stage(.expanded, song, sunset, app: "Música")),
            ("ilha-aberta-pausa", stage(.expanded, paused, sunset, app: "Música")),
            ("ilha-aberta-titulo-longo", stage(.expanded, long, night, app: "Spotify")),
            ("ilha-aberta-radio-sem-capa", stage(.expanded, radio, nil, app: "Safari")),
        ]
    }

    /// The island where it lives: a wallpaper, the menu bar and the notch.
    private static func stage(_ presentation: IslandPresentation, _ track: NowPlayingTrack,
                              _ artwork: IslandArtwork?, app: String) -> AnyView {
        let notch = CGSize(width: 185, height: 32)
        return AnyView(
            ZStack(alignment: .top) {
                LinearGradient(colors: [VibePalette.blue, VibePalette.purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.55)
                VibeColor.canvas.opacity(0.35)
                    .frame(height: notch.height)
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                    .fill(VibeColor.canvas)
                    .frame(width: notch.width, height: notch.height)
                IslandView(presentation: presentation, notch: notch, track: track,
                           artwork: artwork, appName: app)
            }
            .frame(width: 600, height: 190)
            .background(VibeColor.canvas)
        )
    }

    static func fakeTrack(title: String, artist: String, duration: TimeInterval?,
                                  elapsed: TimeInterval) -> NowPlayingTrack {
        NowPlayingTrack(id: title, title: title, artist: artist, album: "", duration: duration,
                        elapsed: elapsed, elapsedSampledAt: Date(), playbackRate: 1, isPlaying: true,
                        bundleID: nil, pid: nil, artwork: nil)
    }

    /// A 300×300 PNG: a diagonal gradient with a pale disc, like a simple sleeve.
    static func fakeCover(_ from: NSColor, _ to: NSColor) -> Data? {
        let side = 300
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [from.cgColor, to.cgColor] as CFArray,
                                        locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0),
                                   options: [])
        context.setFillColor(NSColor(white: 1, alpha: 0.8).cgColor)
        context.fillEllipse(in: CGRect(x: 95, y: 95, width: 110, height: 110))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
