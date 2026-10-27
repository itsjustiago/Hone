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
        ] + claudeIslandPages(song: song, cover: sunset) + externalIslandPages(song: song, cover: sunset)
    }

    /// The island on an external screen, where there is no notch: the virtual one,
    /// the width of a real notch and as tall as a plain menu bar, hangs from the
    /// menu bar (a strip across the top, with no notch cut into it).
    private static func externalIslandPages(song: NowPlayingTrack, cover: IslandArtwork?) -> [(String, AnyView)] {
        let working = ClaudeSnapshot(sessions: [onboarding, login, notes], myAgents: myAgents)
        return [
            ("ilha-externo-compacta",
             stage(.music(.compact), track: song, artwork: cover, app: "Música", external: true)),
            ("ilha-externo-claude-compacta",
             stage(claudeLayout(.compact, working), track: nil, artwork: nil, app: "Música", claude: working,
                   external: true)),
            ("ilha-externo-aberta",
             stage(.music(.expanded), track: song, artwork: cover, app: "Música", external: true)),
        ]
    }

    /// The island with Claude Code's sessions, from a fake snapshot of made-up
    /// sessions (the repository is public: no real names).
    private static func claudeIslandPages(song: NowPlayingTrack, cover: IslandArtwork?) -> [(String, AnyView)] {
        let working = ClaudeSnapshot(sessions: [onboarding, login, notes], myAgents: myAgents)
        let waiting = ClaudeSnapshot(sessions: [checkout, notes], myAgents: myAgents)
        let three = ClaudeSnapshot(sessions: [checkout, onboarding, login], myAgents: myAgents)
        let seven = ClaudeSnapshot(sessions: [checkout, onboarding, login, dependencies, notes, cart, migration],
                                   myAgents: myAgents)
        let waits = IslandNotice(kind: .waiting, sessionID: checkout.id, name: checkout.name)
        let done = IslandNotice(kind: .finished, sessionID: login.id, name: login.name)

        func page(_ name: String, _ layout: IslandLayout, _ claude: ClaudeSnapshot,
                  track: NowPlayingTrack? = nil) -> (String, AnyView) {
            (name, stage(layout, track: track, artwork: track == nil ? nil : cover, app: "Música", claude: claude))
        }
        return [
            page("ilha-claude-compacta", claudeLayout(.compact, working), working),
            page("ilha-claude-espera", claudeLayout(.compact, waiting), waiting),
            page("ilha-claude-aviso", claudeLayout(.peek, waiting, peek: .notice(waits)), waiting),
            page("ilha-claude-aviso-musica",
                 claudeLayout(.peek, working, wings: .music, peek: .notice(done), badge: true), working, track: song),
            page("ilha-compacta-musica-claude", claudeLayout(.compact, waiting, wings: .music, badge: true),
                 waiting, track: song),
            page("ilha-aberta-claude", claudeLayout(.expanded, three, page: .claude), three),
            page("ilha-aberta-claude-scroll", claudeLayout(.expanded, seven, page: .claude), seven),
            page("ilha-aberta-claude-musica",
                 claudeLayout(.expanded, three, wings: .music, page: .claude, selector: true), three, track: song),
            page("ilha-aberta-musica-seletor",
                 claudeLayout(.expanded, three, wings: .music, page: .music, selector: true), three, track: song),
        ]
    }

    /// What `IslandState` would decide for `snapshot`: Claude's wings unless told
    /// otherwise, its rows and strip on its page.
    private static func claudeLayout(_ presentation: IslandPresentation, _ snapshot: ClaudeSnapshot,
                                     wings: IslandWings = .claude, page: IslandPage = .music,
                                     peek: IslandPeek? = nil, selector: Bool = false,
                                     badge: Bool = false) -> IslandLayout {
        let claude = IslandClaude(snapshot)
        var layout = IslandLayout.music(presentation)
        layout.wings = wings
        layout.page = page
        if let peek { layout.peek = peek }
        layout.claudeActivity = claude.activity
        layout.activeSessions = claude.active
        if presentation == .expanded, page == .claude {
            layout.claudeRows = min(claude.listed, IslandMetrics.claudeMaxRows)
            layout.hasAgentsStrip = claude.hasMyAgents
        }
        layout.showsPageSelector = selector
        if badge { layout.coverBadge = claude.activity }
        return layout
    }

    // MARK: Made-up sessions

    private static let myAgents = ["engenheiro", "explorador", "revisor", "testador", "design", "investigador"]
        .map { ClaudeAgentProfile(name: $0, description: "") }

    private static var onboarding: ClaudeSession {
        fakeSession("1", "Refazer o onboarding", "loja", .working, minutes: 3,
                    agents: ["engenheiro", "engenheiro", "engenheiro", "engenheiro", "explorador", "Explore"])
    }
    private static var login: ClaudeSession {
        fakeSession("2", "Corrigir o login", "site", .working, minutes: 12, agents: ["revisor", "Explore"])
    }
    private static var checkout: ClaudeSession {
        fakeSession("3", "Testes do checkout", "loja", .waiting, minutes: 1)
    }
    private static var notes: ClaudeSession {
        fakeSession("4", "Notas de lançamento", "hone", .idle, minutes: 40)
    }
    private static var migration: ClaudeSession {
        fakeSession("5", "Migrar a base de dados", "api", .idle, minutes: 125)
    }
    private static var dependencies: ClaudeSession {
        fakeSession("6", "Atualizar as dependências", "api", .working, minutes: 0.5, agents: ["testador"])
    }
    private static var cart: ClaudeSession {
        fakeSession("7", "Rever o carrinho", "loja", .idle, minutes: 25)
    }

    /// `minutes` ago, from now, so «há N min» reads the same every time.
    private static func fakeSession(_ id: String, _ name: String, _ project: String, _ state: ClaudeSession.State,
                                    minutes: Double, agents: [String] = []) -> ClaudeSession {
        ClaudeSession(id: id, pid: 1, hostSessionID: nil, name: name, project: project, state: state,
                      since: Date().addingTimeInterval(-minutes * 60 - 5),
                      agents: agents.map { ClaudeRunningAgent(type: $0, isMine: $0 != "Explore") })
    }

    /// The island where it lives: a wallpaper, the menu bar and the notch.
    private static func stage(_ presentation: IslandPresentation, _ track: NowPlayingTrack,
                              _ artwork: IslandArtwork?, app: String) -> AnyView {
        stage(.music(presentation), track: track, artwork: artwork, app: app)
    }

    /// `stage` for any layout: taller than the music's 190 points when the island is.
    /// `external`: an external screen, so a plain 24-point menu bar and a virtual
    /// notch (no physical one drawn: the island itself is the notch).
    private static func stage(_ layout: IslandLayout, track: NowPlayingTrack?, artwork: IslandArtwork?,
                              app: String, claude: ClaudeSnapshot? = nil, external: Bool = false) -> AnyView {
        let notch = CGSize(width: IslandMetrics.virtualNotchWidth, height: external ? 24 : 32)
        let height = max(190, IslandMetrics.size(for: layout, notch: notch).height + 30)
        return AnyView(
            ZStack(alignment: .top) {
                LinearGradient(colors: [VibePalette.blue, VibePalette.purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.55)
                VibeColor.canvas.opacity(0.35)
                    .frame(height: notch.height)
                if external {
                    fakeMenuItems(height: notch.height)
                } else {
                    UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                        .fill(VibeColor.canvas)
                        .frame(width: notch.width, height: notch.height)
                }
                IslandView(layout: layout, notch: notch, track: track,
                           artwork: artwork, appName: app, claude: claude)
            }
            .frame(width: 600, height: height)
            .background(VibeColor.canvas)
            .environment(\.islandOffscreen, true)
        )
    }

    /// A menu bar's items, as pale pills: some on the left, some on the right.
    private static func fakeMenuItems(height: CGFloat) -> some View {
        func pills(_ widths: [CGFloat]) -> some View {
            HStack(spacing: 12) {
                ForEach(widths.indices, id: \.self) { Capsule().fill(Color.white.opacity(0.4)).frame(width: widths[$0], height: 6) }
            }
        }
        return HStack {
            pills([10, 34, 26, 30, 38])
            Spacer()
            pills([14, 18, 54])
        }
        .padding(.horizontal, 14)
        .frame(height: height)
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
