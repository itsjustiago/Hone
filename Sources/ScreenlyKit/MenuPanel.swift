import SwiftUI
import AppKit
import HoneDesign

/// Live state the menu-bar panel reflects. Populated by `ScreenlyTool` right
/// before the panel shows so counts, shortcuts and permission stay fresh.
final class ScreenlyMenuModel: ObservableObject {
    @Published var count = 0
    @Published var shortcuts: [String: String] = [:]   // CaptureMode.rawValue → display
    @Published var pickerShortcut = ""                 // colour-picker shortcut display
    @Published var recentColors: [String] = []         // last picked colours, newest first
    @Published var hasScreenRecording = true
    @Published var showsOwnIcon = true                 // separated into its own menu-bar item
}

/// One recent capture as the panel draws it.
struct RecentShotEntry: Identifiable {
    let id: UUID
    let title: String
    let date: Date
    let pinned: Bool
    let thumbnail: NSImage?
}

/// The Screenly panel, shown from its own menu-bar icon or inside Hone's popover
/// (the host owns the `NSPopover`). Reads the live store and model, and hands
/// plain values to `MenuPanelContent`.
struct MenuPanel: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject var model: ScreenlyMenuModel

    var onCapture: (CaptureMode) -> Void
    var onPickColor: () -> Void
    var onPickRecentColor: (String) -> Void
    var onPickRecent: (Shot) -> Void
    var onRevealRecent: (Shot) -> Void
    var onShowGallery: () -> Void
    var onSettings: () -> Void
    var onGrantAccess: () -> Void
    /// Non-nil when shown inside Hone's popover: a "‹" in the header goes back.
    var onBack: (() -> Void)?
    var onToggleOwnIcon: () -> Void

    private var recent: [Shot] { Array(store.orderedItems.prefix(4)) }

    var body: some View {
        MenuPanelContent(
            count: model.count,
            shortcuts: model.shortcuts,
            pickerShortcut: model.pickerShortcut,
            recentColors: model.recentColors,
            recent: recent.map {
                RecentShotEntry(id: $0.id, title: $0.modeTitle, date: $0.date, pinned: $0.pinned,
                                thumbnail: store.thumbnail(for: $0))
            },
            hasScreenRecording: model.hasScreenRecording,
            showsOwnIcon: model.showsOwnIcon,
            hasItems: !store.items.isEmpty,
            onBack: onBack,
            onCapture: onCapture,
            onPickColor: onPickColor,
            onPickRecentColor: onPickRecentColor,
            onPickRecent: { id in if let s = shot(id) { onPickRecent(s) } },
            onRevealRecent: { id in if let s = shot(id) { onRevealRecent(s) } },
            onTogglePin: { id in if let s = shot(id) { store.togglePin(s) } },
            onDelete: { id in if let s = shot(id) { store.delete(s) } },
            onShowGallery: onShowGallery,
            onSettings: onSettings,
            onGrantAccess: onGrantAccess,
            onToggleOwnIcon: onToggleOwnIcon)
    }

    private func shot(_ id: UUID) -> Shot? { recent.first { $0.id == id } }
}

/// Values in, closures out: nothing here touches the real captures, so it
/// renders offscreen from fake data.
struct MenuPanelContent: View {
    let count: Int
    let shortcuts: [String: String]
    let pickerShortcut: String
    let recentColors: [String]
    let recent: [RecentShotEntry]
    let hasScreenRecording: Bool
    let showsOwnIcon: Bool
    let hasItems: Bool
    var onBack: (() -> Void)?
    var onCapture: (CaptureMode) -> Void = { _ in }
    var onPickColor: () -> Void = {}
    var onPickRecentColor: (String) -> Void = { _ in }
    var onPickRecent: (UUID) -> Void = { _ in }
    var onRevealRecent: (UUID) -> Void = { _ in }
    var onTogglePin: (UUID) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onShowGallery: () -> Void = {}
    var onSettings: () -> Void = {}
    var onGrantAccess: () -> Void = {}
    var onToggleOwnIcon: () -> Void = {}

    private var tint: Color { VibeToolColor.screenly }

    var body: some View {
        VStack(spacing: VibeSpacing.cardGap) {
            VibePanelHeader(
                title: "Screenly",
                subtitle: "\(count) \(count == 1 ? "captura" : "capturas")",
                color: tint,
                mood: hasScreenRecording ? .awake : .alert,
                onBack: onBack
            ) {
                VibeOwnIconButton(showsOwnIcon: showsOwnIcon, action: onToggleOwnIcon)
            }

            if !hasScreenRecording {
                VibeNoticeStrip("Ativar gravação de ecrã", color: VibeColor.danger,
                                actionTitle: "Conceder acesso…", action: onGrantAccess)
                    .help("O Hone precisa de permissão de Gravação de Ecrã para o Screenly capturar.")
            }

            actionsCard

            if !recentColors.isEmpty || !recent.isEmpty {
                recentsCard
            }

            VStack(alignment: .leading, spacing: 0) {
                VibeMenuRow("Ver todas as capturas", systemImage: "photo.on.rectangle.angled",
                            action: onShowGallery)
                    .disabled(!hasItems)
                VibeMenuRow("Definições…", systemImage: "gearshape", action: onSettings)
            }
            .vibeMenuCard()
        }
        .vibePanelLayout()
        .vibePanelBackground()
    }

    // MARK: - Capture modes + eyedropper, as pills

    private var actionsCard: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                pill(.region)
                pill(.window)
            }
            GridRow {
                pill(.screen)
                VibeActionPill("Conta-gotas", systemImage: "eyedropper", shortcut: pickerShortcut,
                               tint: tint, action: onPickColor)
                    .help(PickerAction.eyedropper.title)
            }
        }
        .vibeCard(padding: 8)
    }

    private func pill(_ mode: CaptureMode) -> some View {
        VibeActionPill(mode.shortTitle, systemImage: mode.systemImage,
                       shortcut: shortcuts[mode.rawValue] ?? "", tint: tint) { onCapture(mode) }
            .help(mode.title)
    }

    // MARK: - Recent colours + captures

    private var recentsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !recentColors.isEmpty {
                VibeSectionLabel("Cores recentes")
                HStack(spacing: 7) {
                    ForEach(recentColors, id: \.self) { hex in
                        Button { onPickRecentColor(hex) } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(VibePressStyle(scale: 0.92))
                        .help("Copiar \(hex)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
            if !recentColors.isEmpty && !recent.isEmpty { VibeHairline() }
            if !recent.isEmpty {
                VibeSectionLabel("Recentes")
                ForEach(recent) { entry in
                    Button { onPickRecent(entry.id) } label: { RecentShotRow(entry: entry) }
                        .buttonStyle(VibeMenuRowStyle())
                        .contextMenu {
                            Button("Copiar") { onPickRecent(entry.id) }
                            Button("Mostrar no Finder") { onRevealRecent(entry.id) }
                            Button(entry.pinned ? "Desafixar" : "Fixar") { onTogglePin(entry.id) }
                            Button("Apagar", role: .destructive) { onDelete(entry.id) }
                        }
                }
            }
        }
        .vibeMenuCard()
    }
}

// MARK: - Recent row

private struct RecentShotRow: View {
    let entry: RecentShotEntry
    @Environment(\.vibeRowHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(VibeFont.body)
                    .foregroundStyle(highlighted ? VibeColor.text1 : VibeColor.text2)
                    .lineLimit(1)
                Text(entry.date, format: .relative(presentation: .numeric))
                    .font(.system(size: 10))
                    .foregroundStyle(VibeColor.text4)
            }
            Spacer(minLength: 0)
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(VibeToolColor.screenly)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let thumbnail = entry.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "photo")
                .font(.system(size: 11))
                .foregroundStyle(VibeColor.text3)
                .frame(width: 30, height: 20)
                .background(VibeColor.inset, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

// MARK: - Preview fixtures

extension MenuPanelContent {
    /// Fake data for offscreen renders; never the user's real captures.
    static func fixture(hasScreenRecording: Bool) -> MenuPanelContent {
        let now = Date()
        return MenuPanelContent(
            count: 12,
            shortcuts: ["region": "⌃⇧2", "window": "⌃⇧3", "screen": "⌃⇧4"],
            pickerShortcut: "⌃⇧1",
            recentColors: ["#EED65E", "#5AA2F0", "#EF86C0", "#60C97A", "#C58AF2", "#E25C62"],
            recent: [
                RecentShotEntry(id: UUID(), title: "Região", date: now.addingTimeInterval(-120), pinned: true, thumbnail: nil),
                RecentShotEntry(id: UUID(), title: "Janela", date: now.addingTimeInterval(-3600), pinned: false, thumbnail: nil),
                RecentShotEntry(id: UUID(), title: "Ecrã inteiro", date: now.addingTimeInterval(-86400), pinned: false, thumbnail: nil),
            ],
            hasScreenRecording: hasScreenRecording,
            showsOwnIcon: true,
            hasItems: true)
    }
}

/// Entry point for Hone's offscreen preview renders.
public enum ScreenlyPreview {
    @MainActor
    public static func panel(hasScreenRecording: Bool = true, back: (() -> Void)? = nil) -> AnyView {
        var content = MenuPanelContent.fixture(hasScreenRecording: hasScreenRecording)
        content.onBack = back
        return AnyView(content)
    }

    /// The tool's page in Settings, with the stored values.
    @MainActor
    public static func settings() -> AnyView {
        AnyView(SettingsController().makeView())
    }
}
