import SwiftUI
import AppKit
import HoneDesign

/// Live state the menu-bar panel reflects. Populated by `ClippyTool` right
/// before the panel opens so recent items and permissions stay fresh.
final class ClipMenuModel: ObservableObject {
    @Published var shortcut = Shortcut.display
    @Published var hasAccessibility = PasteHelper.hasAccessibility(prompt: false)
    /// Mirrors `ClippyTool.showsOwnMenuBarIcon` for the split/merge button.
    @Published var showsOwnIcon = ClippyDefaults.showsOwnMenuBarIcon
}

/// One recent clipboard item as the panel draws it.
struct RecentEntry: Identifiable {
    let id: UUID
    let label: String
    let thumbnail: NSImage?
}

/// The panel shown from the menu-bar icon, or inside Hone's popover. Reads the
/// live store and model, and hands plain values to `MenuPanelContent`.
struct MenuPanel: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var model: ClipMenuModel

    /// Non-nil when shown inside Hone's popover: the header gets a back chevron.
    var onBack: (() -> Void)?
    var onShowHistory: () -> Void
    var onPickRecent: (ClipItem) -> Void
    var onClear: () -> Void
    var onSettings: () -> Void
    var onGrantAccess: () -> Void
    var onToggleOwnIcon: () -> Void

    private var recent: [ClipItem] { Array(store.orderedItems.prefix(5)) }

    var body: some View {
        MenuPanelContent(
            itemCount: store.items.count,
            recent: recent.map { item in
                RecentEntry(id: item.id,
                            label: item.kind == .image
                                ? "Imagem"
                                : item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                            thumbnail: item.kind == .image ? store.thumbnail(for: item) : nil)
            },
            shortcut: model.shortcut,
            hasAccessibility: model.hasAccessibility,
            showsOwnIcon: model.showsOwnIcon,
            onBack: onBack,
            onShowHistory: onShowHistory,
            onPickRecent: { id in
                if let item = recent.first(where: { $0.id == id }) { onPickRecent(item) }
            },
            onClear: onClear,
            onSettings: onSettings,
            onGrantAccess: onGrantAccess,
            onToggleOwnIcon: onToggleOwnIcon)
    }
}

/// Values in, closures out: nothing here touches the real history, so it
/// renders offscreen from fake data.
struct MenuPanelContent: View {
    let itemCount: Int
    let recent: [RecentEntry]
    let shortcut: String
    let hasAccessibility: Bool
    let showsOwnIcon: Bool
    var onBack: (() -> Void)?
    var onShowHistory: () -> Void = {}
    var onPickRecent: (UUID) -> Void = { _ in }
    var onClear: () -> Void = {}
    var onSettings: () -> Void = {}
    var onGrantAccess: () -> Void = {}
    var onToggleOwnIcon: () -> Void = {}

    var body: some View {
        VStack(spacing: VibeSpacing.cardGap) {
            VibePanelHeader(
                title: "Clippy",
                subtitle: "\(itemCount) \(itemCount == 1 ? "item" : "itens")",
                color: VibeToolColor.clippy,
                mood: hasAccessibility ? .awake : .alert,
                onBack: onBack
            ) {
                VibeOwnIconButton(showsOwnIcon: showsOwnIcon, action: onToggleOwnIcon)
            }

            if !hasAccessibility {
                VibeNoticeStrip("Ativar colar automático", color: VibeColor.danger,
                                actionTitle: "Conceder acesso…", action: onGrantAccess)
                    .help("O Clippy precisa de Acessibilidade para colar por ti.")
            }

            VStack(alignment: .leading, spacing: 0) {
                VibeMenuRow("Mostrar histórico", systemImage: "clock.arrow.circlepath",
                            shortcut: shortcut, action: onShowHistory)
                if !recent.isEmpty {
                    VibeSectionLabel("Recentes")
                    ForEach(recent) { entry in
                        Button { onPickRecent(entry.id) } label: { RecentRow(entry: entry) }
                            .buttonStyle(VibeMenuRowStyle())
                    }
                }
            }
            .vibeMenuCard()

            VStack(alignment: .leading, spacing: 0) {
                VibeMenuRow("Limpar histórico", systemImage: "trash", action: onClear)
                    .disabled(itemCount == 0)
                VibeMenuRow("Definições…", systemImage: "gearshape", action: onSettings)
            }
            .vibeMenuCard()
        }
        .vibePanelLayout()
        .vibePanelBackground()
    }
}

// MARK: - Recent row

private struct RecentRow: View {
    let entry: RecentEntry
    @Environment(\.vibeRowHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(entry.label)
                .font(VibeFont.body)
                .foregroundStyle(highlighted ? VibeColor.text1 : VibeColor.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var icon: some View {
        if let thumbnail = entry.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "text.alignleft")
                .font(.system(size: 11))
                .foregroundStyle(VibeColor.text3)
                .frame(width: 18, height: 18)
        }
    }
}

// MARK: - Preview fixtures

extension MenuPanelContent {
    /// Fake data for offscreen renders; never the user's real history.
    static func fixture(hasAccessibility: Bool) -> MenuPanelContent {
        let texts = ["Reunião às 15h com a equipa de design", "https://hone.app/download", "npm run build && npm test", "Imagem"]
        return MenuPanelContent(
            itemCount: 38,
            recent: texts.map { RecentEntry(id: UUID(), label: $0, thumbnail: nil) },
            shortcut: "⌃⇧V",
            hasAccessibility: hasAccessibility,
            showsOwnIcon: true)
    }
}

/// Entry point for Hone's offscreen preview renders.
public enum ClippyPreview {
    @MainActor
    public static func panel(hasAccessibility: Bool = true, back: (() -> Void)? = nil) -> AnyView {
        var content = MenuPanelContent.fixture(hasAccessibility: hasAccessibility)
        content.onBack = back
        return AnyView(content)
    }
}
