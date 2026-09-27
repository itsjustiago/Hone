import SwiftUI
import AppKit

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

/// The Screenly panel — shown from its own menu-bar icon or inside Hone's popover
/// (the host owns the `NSPopover`), styled to match the rest of the family
/// (300pt wide, `.menu` vibrancy).
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

    private let panelWidth: CGFloat = 300
    private let edge: CGFloat = 8
    private var contentInset: CGFloat { 14 }   // edge (8) + inner pad (6)

    private var recent: [Shot] { Array(store.orderedItems.prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, contentInset)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if !model.hasScreenRecording {
                permissionBanner
                    .padding(.horizontal, edge)
                    .padding(.bottom, 8)
            }

            // Primary actions: the three capture modes + the colour picker.
            VStack(spacing: 1) {
                ForEach(CaptureMode.allCases) { mode in
                    MenuButton(action: { onCapture(mode) }) {
                        MenuActionLabel(title: mode.title,
                                        shortcut: model.shortcuts[mode.rawValue] ?? "",
                                        systemImage: mode.systemImage)
                    }
                }
                MenuButton(action: onPickColor) {
                    MenuActionLabel(title: PickerAction.eyedropper.title,
                                    shortcut: model.pickerShortcut,
                                    systemImage: "eyedropper")
                }
            }
            .padding(.horizontal, edge)

            recentColorsSection

            recentSection

            Divider()
                .padding(.horizontal, contentInset)
                .padding(.vertical, 8)

            VStack(spacing: 1) {
                MenuButton(action: onShowGallery) {
                    MenuActionLabel(title: "Ver todas as capturas", shortcut: "",
                                    systemImage: "photo.on.rectangle.angled")
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
            AppIcon(systemName: "camera.viewfinder", size: 27)
            VStack(alignment: .leading, spacing: 0) {
                Text("Screenly").font(.system(size: 15, weight: .bold))
                Text("\(model.count) \(model.count == 1 ? "captura" : "capturas")")
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

    // MARK: - Recent colours

    @ViewBuilder private var recentColorsSection: some View {
        if !model.recentColors.isEmpty {
            Text("CORES RECENTES")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, contentInset)
                .padding(.top, 12)
                .padding(.bottom, 5)

            HStack(spacing: 7) {
                ForEach(model.recentColors, id: \.self) { hex in
                    Button { onPickRecentColor(hex) } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.15))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copiar \(hex)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, contentInset)
        }
    }

    // MARK: - Recent captures

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
                ForEach(recent, id: \.id) { shot in
                    MenuButton(action: { onPickRecent(shot) }) {
                        RecentShotRow(shot: shot, thumbnail: store.thumbnail(for: shot))
                    }
                    .contextMenu {
                        Button("Copiar") { onPickRecent(shot) }
                        Button("Mostrar no Finder") { onRevealRecent(shot) }
                        Button(shot.pinned ? "Desafixar" : "Fixar") { store.togglePin(shot) }
                        Button("Apagar", role: .destructive) { store.delete(shot) }
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
                Text("Ativar gravação de ecrã")
                    .font(.subheadline.weight(.medium))
                Text("O Hone precisa de permissão de Gravação de Ecrã para o Screenly capturar.")
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

private struct RecentShotRow: View {
    let shot: Shot
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(shot.modeTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(shot.date, format: .relative(presentation: .numeric))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if shot.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "photo")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 22)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

// MARK: - Menu action label + button style (redefined per panel, as in the family)

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

/// Row button with native-menu hover highlight.
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

/// The system menu material (translucent vibrancy), matching the family's menus.
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
