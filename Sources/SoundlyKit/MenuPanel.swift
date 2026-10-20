import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HoneDesign

/// The Soundly panel, shown from its own menu-bar icon or inside Hone's popover.
/// Reads the live mixer and the list model and hands plain values to
/// `SoundlyPanelContent`, which renders offscreen from fake data.
struct SoundlyPanel: View {
    @ObservedObject var mixer: SoundlyMixer
    @ObservedObject var list: SoundlyListModel

    /// Non-nil when hosted inside Hone's popover: the header shows a back chevron.
    var onBack: (() -> Void)?
    var onSettings: () -> Void
    var onToggleOwnIcon: () -> Void

    var body: some View {
        SoundlyPanelContent(
            apps: list.apps,
            permission: mixer.permission,
            outputName: mixer.outputDeviceName,
            showsOwnIcon: list.showsOwnIcon,
            onBack: onBack,
            onVolume: { id, volume in mixer.setVolume(volume, for: id) },
            onMute: { id, muted in mixer.setMuted(muted, for: id) },
            onEditing: list.setDragging,
            onRequestAccess: mixer.requestPermission,
            onOpenPrivacySettings: mixer.openPermissionSettings,
            onSettings: onSettings,
            onToggleOwnIcon: onToggleOwnIcon)
            // The user may have changed the permission in System Settings meanwhile.
            .onAppear { mixer.refreshPermission() }
    }
}

/// Values in, closures out, so it renders offscreen from fake data.
struct SoundlyPanelContent: View {
    let apps: [SoundlyApp]
    let permission: SoundlyPermission
    let outputName: String?
    let showsOwnIcon: Bool
    /// A long list scrolls. Offscreen renders can't draw a `ScrollView`.
    var scrollsLongList = true
    var onBack: (() -> Void)?
    var onVolume: (SoundlyApp.ID, Double) -> Void = { _, _ in }
    var onMute: (SoundlyApp.ID, Bool) -> Void = { _, _ in }
    /// A slider was grabbed (`true`) or let go (`false`).
    var onEditing: (Bool) -> Void = { _ in }
    var onRequestAccess: () -> Void = {}
    var onOpenPrivacySettings: () -> Void = {}
    var onSettings: () -> Void = {}
    var onToggleOwnIcon: () -> Void = {}

    /// More rows than this and the list scrolls, showing half of the next one
    /// so it reads as scrollable.
    static let visibleRows = 5
    static let rowHeight: CGFloat = 52

    private var tint: Color { VibeToolColor.soundly }

    var body: some View {
        // Pinned to the top: the list grows and shrinks as apps start and stop
        // making sound while the popover is open, and SwiftUI would centre the
        // content in the moving frame, making everything slide.
        VibeTopAnchoredLayout { content }
            .vibePanelBackground()
            // Keep controls fully coloured even when the popover window isn't key.
            .environment(\.controlActiveState, .active)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: VibeSpacing.cardGap) {
            header
            if let notice = SoundlyNotice.current(permission: permission, apps: apps) {
                noticeBanner(notice)
            }
            if apps.isEmpty { emptyState } else { list }
            VibeMenuRow("Definições…", systemImage: "gearshape", action: onSettings)
                .vibeMenuCard()
        }
        .vibePanelLayout()
    }

    // MARK: Header

    private var header: some View {
        VibePanelHeader(title: "Soundly", subtitle: outputName ?? "Sem saída de áudio",
                        color: tint, mood: .awake, onBack: onBack) {
            VibeOwnIconButton(showsOwnIcon: showsOwnIcon, action: onToggleOwnIcon)
        }
    }

    // MARK: Notice

    @ViewBuilder
    private func noticeBanner(_ notice: SoundlyNotice) -> some View {
        switch notice {
        case .requestAccess:
            VibeBanner(color: VibeColor.warning, title: "Falta acesso ao áudio",
                       detail: "Dá acesso ao áudio das apps para ajustar o volume.",
                       actionTitle: "Dar acesso", stacked: true, action: onRequestAccess)
        case .accessDenied:
            VibeBanner(color: VibeColor.danger, title: "Acesso negado",
                       detail: "Ativa o Hone em Definições › Privacidade › Gravação de ecrã e áudio do sistema e reinicia o Hone.",
                       actionTitle: "Abrir Definições", stacked: true, action: onOpenPrivacySettings)
        }
    }

    // MARK: List

    private var list: some View {
        Group {
            if scrollsLongList, apps.count > Self.visibleRows {
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .frame(height: Self.rowHeight * (CGFloat(Self.visibleRows) + 0.5))
            } else {
                rows
            }
        }
        .vibeMenuCard()
        .animation(VibeMotion.standard, value: apps.map(\.id))
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { VibeHairline() }
                SoundlyAppRow(
                    app: app, tint: tint,
                    onVolume: { onVolume(app.id, $0) },
                    onMute: { onMute(app.id, $0) },
                    onEditing: onEditing)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(VibeColor.text4)
                .accessibilityHidden(true)
            Text("Nenhuma app com som aberta")
                .font(VibeFont.body)
                .foregroundStyle(VibeColor.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .vibeCard(padding: 16)
    }
}

// MARK: - Row

/// One app: its icon and name, a mute button, the volume slider and the value.
private struct SoundlyAppRow: View {
    let app: SoundlyApp
    let tint: Color
    let onVolume: (Double) -> Void
    let onMute: (Bool) -> Void
    let onEditing: (Bool) -> Void

    private var failure: String? {
        if case .unavailable(let reason) = app.status { return reason }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SoundlyAppIcon(url: app.bundleURL)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                nameLine
                controls
                if let failure { failureLine(failure) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.name)
    }

    private var nameLine: some View {
        HStack(spacing: 8) {
            Text(app.name)
                .font(VibeFont.action)
                .foregroundStyle(VibeColor.text1)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if app.isPlaying {
                HStack(spacing: 5) {
                    VibeDot(tint, size: 5)
                    Text("a tocar")
                        .font(VibeFont.caption)
                        .foregroundStyle(VibeColor.text3)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
        // Dimmed like the controls, so the row reads as one: the reason below is not.
        .opacity(failure == nil ? 1 : 0.5)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            SoundlyMuteButton(isMuted: app.isMuted, name: app.name) { onMute(!app.isMuted) }
            VibeSlider(
                value: Binding(
                    get: { app.volume },
                    set: { volume in
                        // Moving a muted app's slider means "let me hear it".
                        if app.isMuted { onMute(false) }
                        onVolume(volume)
                    }),
                label: "Volume de \(app.name)",
                tint: app.isMuted ? VibeColor.text4 : tint,
                onEditingChanged: onEditing)
            Text(SoundlyFormat.percent(app.volume))
                .font(VibeFont.caption.monospacedDigit())
                .foregroundStyle(app.isMuted ? VibeColor.text4 : VibeColor.text2)
                .frame(width: 38, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onVolume(1) }
                .help("Duplo clique para repor 100 %")
                .accessibilityHidden(true)
        }
        .opacity(failure == nil ? 1 : 0.5)
    }

    private func failureLine(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            VibeDot(VibeColor.warning, size: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(reason)
                .font(VibeFont.caption)
                .foregroundStyle(VibeColor.text3)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

/// The speaker before the slider: a tap mutes or unmutes the app.
private struct SoundlyMuteButton: View {
    let isMuted: Bool
    let name: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isMuted || hovering ? VibeColor.text1 : VibeColor.text3)
                .frame(width: 26, height: 26)
                .background(isMuted || hovering ? VibeColor.control : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(VibePressStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .animation(VibeMotion.quick, value: isMuted)
        .help(isMuted ? "Tirar o silêncio de \(name)" : "Silenciar \(name)")
        .accessibilityLabel(isMuted ? "Tirar o silêncio de \(name)" : "Silenciar \(name)")
    }
}

/// An app's icon from its bundle, a generic one when it has none.
private struct SoundlyAppIcon: View {
    let url: URL?

    var body: some View {
        Image(nsImage: SoundlyIcons.icon(for: url))
            .resizable()
            .interpolation(.high)
            .accessibilityHidden(true)
    }
}

/// Icons are looked up once per app: the panel redraws on every slider step.
@MainActor
enum SoundlyIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL?) -> NSImage {
        guard let url else { return generic }
        // Resolved, or a symlinked bundle (Safari lives in a cryptex) gets the
        // alias arrow stamped on its icon.
        let path = url.resolvingSymlinksInPath().path
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }

    private static let generic = NSWorkspace.shared.icon(for: .application)
}

// MARK: - Preview fixtures

/// Entry point for Hone's offscreen preview renders: fake apps, no audio touched.
public enum SoundlyPreview {
    public enum Scenario: Sendable {
        /// A playing app at 35 %, one at full volume, one muted, one that failed.
        case apps
        /// The same, and the permission was never asked.
        case needsAccess
        /// The same, and the permission was refused.
        case denied
        /// Nothing is making sound.
        case empty
        /// More apps than fit: the list scrolls (not drawable offscreen, so it lays all out).
        case many
    }

    @MainActor
    public static func panel(_ scenario: Scenario = .apps, back: (() -> Void)? = nil) -> AnyView {
        let apps: [SoundlyApp]
        switch scenario {
        case .apps, .needsAccess, .denied: apps = sample(needingPermission: scenario != .apps)
        case .empty: apps = []
        case .many: apps = sample(needingPermission: false) + more
        }
        let permission: SoundlyPermission
        switch scenario {
        case .needsAccess: permission = .unknown
        case .denied: permission = .denied
        default: permission = .granted
        }
        return AnyView(SoundlyPanelContent(
            apps: apps, permission: permission, outputName: "Nothing Ear (a)", showsOwnIcon: true,
            scrollsLongList: false, onBack: back))
    }

    @MainActor
    public static func settings() -> AnyView {
        AnyView(SoundlySettingsView(onResetAll: {}))
    }

    private static func fake(_ id: String, _ name: String, path: String, playing: Bool = false,
                             volume: Double = 1, muted: Bool = false,
                             status: SoundlyApp.Status = .direct) -> SoundlyApp {
        SoundlyApp(id: id, name: name, bundleURL: URL(fileURLWithPath: path), pids: [1],
                   isPlaying: playing, level: SoundlyLevel(volume: volume, isMuted: muted), status: status)
    }

    private static func sample(needingPermission: Bool) -> [SoundlyApp] {
        [
            fake("com.apple.Music", "Música", path: "/System/Applications/Music.app", playing: true,
                 volume: 0.35, status: needingPermission ? .needsPermission : .adjusted),
            fake("com.apple.Safari", "Safari", path: "/Applications/Safari.app", playing: true),
            fake("com.apple.podcasts", "Podcasts", path: "/System/Applications/Podcasts.app",
                 volume: 0.6, muted: true, status: needingPermission ? .needsPermission : .adjusted),
            fake("com.apple.TV", "TV", path: "/System/Applications/TV.app", volume: 0.5,
                 status: .unavailable("A saída «Mesa + colunas» não pode ser usada (dispositivo agregado ou de várias saídas).")),
        ]
    }

    private static var more: [SoundlyApp] {
        [
            fake("com.apple.FaceTime", "FaceTime", path: "/System/Applications/FaceTime.app"),
            fake("com.apple.Notes", "Notas", path: "/System/Applications/Notes.app"),
            fake("com.apple.Maps", "Mapas", path: "/System/Applications/Maps.app"),
        ]
    }
}
