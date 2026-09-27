import AppKit
import SwiftUI

/// Owns the gallery window that shows every capture in a searchable grid.
final class GalleryController: NSObject, NSWindowDelegate {
    private let store: CaptureStore
    private var window: NSWindow?

    init(store: CaptureStore) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil { build() }
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    private func build() {
        let view = GalleryView(store: store)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Capturas — Screenly"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.minSize = NSSize(width: 520, height: 400)
        w.delegate = self
        w.contentView = NSHostingView(rootView: view)
        window = w
    }
}

struct GalleryView: View {
    @ObservedObject var store: CaptureStore
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    private var items: [Shot] {
        let base = store.orderedItems
        guard !query.isEmpty else { return base }
        return base.filter { $0.modeTitle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.4)
            if items.isEmpty {
                emptyState
            } else {
                grid
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(.background)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Pesquisar capturas…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items, id: \.id) { shot in
                    GalleryCell(shot: shot, thumbnail: store.thumbnail(for: shot),
                                onCopy: { copy(shot) },
                                onReveal: { reveal(shot) },
                                onTogglePin: { store.togglePin(shot) },
                                onDelete: { store.delete(shot) })
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Sem capturas ainda" : "Sem resultados")
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Text("Usa um atalho ou o menu para tirar a primeira.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var footer: some View {
        HStack {
            Text("\(store.items.count) \(store.items.count == 1 ? "captura" : "capturas")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !store.items.isEmpty {
                Button(role: .destructive) { store.clearUnpinned() } label: {
                    Label("Limpar", systemImage: "trash").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Apaga as capturas não fixadas")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func copy(_ shot: Shot) {
        guard let img = NSImage(contentsOf: store.imageURL(for: shot)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    private func reveal(_ shot: Shot) {
        let saved = shot.savedPath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([saved ?? store.imageURL(for: shot)])
    }
}

private struct GalleryCell: View {
    let shot: Shot
    let thumbnail: NSImage?
    var onCopy: () -> Void
    var onReveal: () -> Void
    var onTogglePin: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumb
                if shot.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(6)
                }
                if hovering {
                    hoverActions
                }
            }
            HStack(spacing: 5) {
                Text(shot.modeTitle)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(shot.date, format: .relative(presentation: .numeric))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Copiar") { onCopy() }
            Button("Mostrar no Finder") { onReveal() }
            Button(shot.pinned ? "Desafixar" : "Fixar") { onTogglePin() }
            Button("Apagar", role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder private var thumb: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        )
        .onTapGesture(count: 2) { onReveal() }
        .onTapGesture { onCopy() }
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            iconButton("doc.on.doc", help: "Copiar", action: onCopy)
            iconButton("magnifyingglass", help: "Mostrar no Finder", action: onReveal)
            iconButton("trash", help: "Apagar", action: onDelete)
        }
        .padding(6)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
