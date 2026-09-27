import SwiftUI
import AppKit

/// Live state the menu-bar panel reflects. Populated by `ClippyTool` right
/// before the panel opens so recent items and permissions stay fresh.
final class ClipMenuModel: ObservableObject {
    @Published var shortcut = Shortcut.display
    @Published var hasAccessibility = PasteHelper.hasAccessibility(prompt: false)
    /// Mirrors `ClippyTool.showsOwnMenuBarIcon` for the split/merge button.
    @Published var showsOwnIcon = ClippyDefaults.showsOwnMenuBarIcon
}

/// The panel shown from the menu-bar icon, or inside Hone's popover,
/// styled to match Facet's `.window` menu.
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

    private let panelWidth: CGFloat = 300
    private let edge: CGFloat = 8
    private var contentInset: CGFloat { 14 }   // edge (8) + inner pad (6)

    private var recent: [ClipItem] { Array(store.orderedItems.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, contentInset)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if !model.hasAccessibility {
                permissionBanner
                    .padding(.horizontal, edge)
                    .padding(.bottom, 8)
            }

            // Primary action: open the full history panel.
            VStack(spacing: 1) {
                MenuButton(action: onShowHistory) {
                    MenuActionLabel(title: "Mostrar histórico", shortcut: model.shortcut,
                                    systemImage: "clock.arrow.circlepath")
                }
            }
            .padding(.horizontal, edge)

            recentSection

            Divider()
                .padding(.horizontal, contentInset)
                .padding(.vertical, 8)

            VStack(spacing: 1) {
                MenuButton(action: onClear) {
                    MenuActionLabel(title: "Limpar histórico", shortcut: "",
                                    systemImage: "trash")
                }
                .disabled(store.items.isEmpty)
                MenuButton(action: onSettings) {
                    MenuActionLabel(title: "Definições…", shortcut: "",
                                    systemImage: "gearshape")
                }
            }
            .padding(.horizontal, edge)
            .padding(.bottom, 8)
        }
        .frame(width: panelWidth)
        .background(VisualEffectBackground())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            if let onBack {
                HeaderIconButton(systemName: "chevron.left", help: "Voltar ao Hone", action: onBack)
                    .padding(.leading, -6)
                    .padding(.trailing, -4)
            }
            AppIcon(systemName: "doc.on.clipboard.fill", size: 27)
            VStack(alignment: .leading, spacing: 0) {
                Text("Clippy").font(.system(size: 15, weight: .bold))
                Text("\(store.items.count) \(store.items.count == 1 ? "item" : "itens")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HeaderIconButton(
                systemName: model.showsOwnIcon ? "menubar.arrow.down.rectangle" : "menubar.arrow.up.rectangle",
                help: model.showsOwnIcon
                    ? "Tirar o ícone próprio (continua no menu do Hone)"
                    : "Separar num ícone próprio na barra de menus",
                action: onToggleOwnIcon)
        }
    }

    // MARK: - Recent items

    @ViewBuilder private var recentSection: some View {
        if !recent.isEmpty {
            Text("RECENTES")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, contentInset)
                .padding(.top, 12)
                .padding(.bottom, 4)

            VStack(spacing: 1) {
                ForEach(recent, id: \.id) { item in
                    MenuButton(action: { onPickRecent(item) }) {
                        RecentRow(item: item,
                                  thumbnail: item.kind == .image ? store.thumbnail(for: item) : nil)
                    }
                }
            }
            .padding(.horizontal, edge)
        }
    }

    // MARK: - Banners

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ativar colar automático")
                    .font(.subheadline.weight(.medium))
                Text("O Clippy precisa de Acessibilidade para colar por ti.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Conceder acesso…", action: onGrantAccess)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Recent row

private struct RecentRow: View {
    let item: ClipItem
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var icon: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "text.alignleft")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var label: String {
        if item.kind == .image { return "Imagem" }
        return item.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Menu action label + button style

struct MenuActionLabel: View {
    let title: String
    let shortcut: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 27)
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            if !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Small circular glyph button for the panel header (back, separate/join).
/// Same spec as the gear on Hone's tool rows: 24 pt circle, quiet at rest, a
/// soft `.primary` pill only under the pointer.
struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(hovering ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Row button with native-menu hover highlight, matching Facet.
struct MenuButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering && isEnabled ? AnyShapeStyle(Brand.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The system menu material (translucent vibrancy), matching Facet's
/// `MenuBarExtra(.window)` background so all three menus share one look.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
