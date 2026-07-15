import SwiftUI

/// The full-screen switcher: a dimmed backdrop with a centred grid of every open
/// window. The highlighted tile tracks `selection.index`, which the controller
/// bumps on each Tab; the view re-renders through the Observation framework.
struct AltTabView: View {
    let selection: AltTabSelection
    var tint: Color = .teal

    private let tileWidth: CGFloat = 208
    private let thumbHeight: CGFloat = 122

    var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()

            VStack(spacing: 14) {
                grid
                caption
            }
            .padding(22)
            .frame(maxWidth: 1140)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 40, y: 18)
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(selection.entries) { entry in
                        WindowTile(entry: entry,
                                   selected: entry.id == selection.index,
                                   tint: tint,
                                   width: tileWidth,
                                   thumbHeight: thumbHeight)
                            .id(entry.id)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: NSScreen.main.map { $0.frame.height * 0.66 } ?? 620)
            .fixedSize(horizontal: false, vertical: selection.entries.count <= 10)
            .onChange(of: selection.index) { _, index in
                withAnimation(.easeOut(duration: 0.14)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var caption: some View {
        let entry = selection.entries.indices.contains(selection.index)
            ? selection.entries[selection.index] : nil
        HStack(spacing: 8) {
            if let icon = entry?.appIcon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            Text(entry?.appName ?? "")
                .fontWeight(.semibold)
            if let title = entry?.window.title, !title.isEmpty {
                Text("— \(title)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 14))
        .frame(maxWidth: 640)
    }
}

/// A single window preview: thumbnail (or app-icon placeholder), app-icon badge,
/// title, and a selection ring driven by the switcher's highlight.
private struct WindowTile: View {
    let entry: AltTabEntry
    let selected: Bool
    let tint: Color
    let width: CGFloat
    let thumbHeight: CGFloat

    var body: some View {
        VStack(spacing: 7) {
            thumbnail
            HStack(spacing: 5) {
                if let icon = entry.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                }
                Text(entry.window.title.isEmpty ? entry.appName : entry.window.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: width - 12)
        }
        .padding(8)
        .background(selected ? tint.opacity(0.20) : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.clear),
                              lineWidth: 2.5)
        )
        .scaleEffect(selected ? 1 : 0.97)
        .opacity(selected ? 1 : 0.82)
        .animation(.easeOut(duration: 0.13), value: selected)
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            if let cg = entry.window.thumbnail {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.gray.opacity(0.16))
                if let icon = entry.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 52, height: 52)
                } else {
                    Image(systemName: "macwindow")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width - 16, height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .saturation(entry.window.isMinimized ? 0.7 : 1)
        .overlay(alignment: .bottomLeading) {
            // Small app badge in the corner when the thumbnail itself is the window.
            if entry.window.thumbnail != nil, let icon = entry.appIcon {
                Image(nsImage: icon).resizable()
                    .frame(width: 24, height: 24)
                    .padding(5)
                    .shadow(radius: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if entry.window.isMinimized {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.orange, in: Circle())
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}
