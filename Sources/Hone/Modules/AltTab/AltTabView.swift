import SwiftUI

/// The full-screen switcher: a dimmed backdrop with a centred grid of every open
/// window. The highlighted tile tracks `selection.index`, which the controller
/// bumps on each Tab; the view re-renders through the Observation framework.
struct AltTabView: View {
    let selection: AltTabSelection
    var tint: Color = .teal
    /// Click a tile — focus that window now.
    var onPick: (AltTabEntry) -> Void = { _ in }
    /// Mouse moved over a tile — make it the highlight.
    var onHover: (Int) -> Void = { _ in }
    /// The tile's X was clicked — close that window, keep switching.
    var onClose: (AltTabEntry) -> Void = { _ in }
    /// Click outside the grid — dismiss without switching.
    var onCancel: () -> Void = {}

    private let tileWidth: CGFloat = 208
    private let thumbHeight: CGFloat = 122
    /// One number for every gap inside the panel — tile-to-tile and tile-to-edge —
    /// so the material reads as an even margin around the grid on all four sides.
    private let gap: CGFloat = 14
    /// Breathing room between the panel and the edge of the screen.
    private let screenInset: CGFloat = 40
    /// Never spread wider than this, however big the display is.
    private let maxColumns = 5

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.32).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onCancel() }

                panel(in: geo.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    /// The panel is sized from the grid it draws — exactly the columns wide and the
    /// rows tall that the open windows need — instead of stretching to a fixed
    /// width, which used to leave a wide band of empty material beside the tiles.
    private func panel(in size: CGSize) -> some View {
        let columns = columnCount(in: size.width)
        let gridWidth = CGFloat(columns) * tileWidth + CGFloat(columns - 1) * gap

        return VStack(spacing: gap) {
            grid(columns: columns, maxHeight: maxGridHeight(in: size.height))
            caption.frame(maxWidth: gridWidth)
        }
        .frame(width: gridWidth)
        .padding(gap)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 40, y: 18)
        .padding(screenInset)
    }

    /// How many tiles fit per row. Past the point where they'd wrap, the columns
    /// are levelled down so the rows are evenly filled — six windows land as 3×2
    /// rather than 5 + a lonely one, which keeps the panel compact.
    private func columnCount(in width: CGFloat) -> Int {
        let usable = width - 2 * (screenInset + gap)
        let fits = max(1, Int((usable + gap) / (tileWidth + gap)))
        let cap = min(fits, maxColumns)
        let count = max(1, selection.entries.count)
        guard count > cap else { return count }
        let rows = (count + cap - 1) / cap
        return (count + rows - 1) / rows
    }

    /// Leave the grid at most two thirds of the display, and never more than what
    /// the panel can hold once the caption and the margins have taken their share.
    private func maxGridHeight(in height: CGFloat) -> CGFloat {
        let room = height - 2 * (screenInset + gap) - captionRoom
        return max(thumbHeight, min(height * 0.66, room))
    }

    /// Caption line plus the gap above it.
    private var captionRoom: CGFloat { 24 + gap }

    private func grid(columns: Int, maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: gap),
                                   count: columns),
                    spacing: gap
                ) {
                    ForEach(selection.entries) { entry in
                        WindowTile(entry: entry,
                                   selected: entry.id == selection.index,
                                   tint: tint,
                                   width: tileWidth,
                                   thumbHeight: thumbHeight,
                                   onPick: { onPick(entry) },
                                   onHover: { if $0 { onHover(entry.id) } },
                                   onClose: { onClose(entry) })
                            .id(entry.id)
                    }
                }
            }
            // Hug the rows, and only start scrolling once they'd outgrow the screen —
            // otherwise a short list sits in a tall, half-empty panel.
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
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
                .lineLimit(1)
                .layoutPriority(1)
            if let title = entry?.window.title, !title.isEmpty {
                Text("— \(title)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 14))
    }
}

/// A single window preview: thumbnail (or app-icon placeholder), app-icon badge,
/// title, a selection ring driven by the switcher's highlight, and the close
/// button that appears under the pointer.
private struct WindowTile: View {
    let entry: AltTabEntry
    let selected: Bool
    let tint: Color
    let width: CGFloat
    let thumbHeight: CGFloat
    var onPick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}

    /// Pointer over the tile — what reveals the close button.
    @State private var hovering = false
    /// Pointer over the close button itself, which then goes red.
    @State private var closeHovering = false

    /// The macOS close-button red, so the affordance reads as the red dot itself.
    private static let closeRed = Color(red: 1, green: 0.37, blue: 0.34)

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
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onPick)
        .onHover { inside in
            hovering = inside
            if !inside { closeHovering = false }
            onHover(inside)
        }
    }

    /// The close affordance, in the corner the red button sits in on every real
    /// window. It only fades in under the pointer, so a keyboard-driven switch
    /// stays free of chrome — and it can't be clicked while invisible, which
    /// leaves the whole tile picking the window as before.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                // Dark disc with a hairline rim: legible over a bright thumbnail
                // and over the grey icon placeholder alike. Under the pointer it
                // lights up in the traffic-light red of the button it stands for.
                .background(closeHovering ? Self.closeRed : .black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { closeHovering = $0 }
        .padding(6)
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.82)
        .allowsHitTesting(hovering)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: closeHovering)
        .help("Fechar janela")
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
        .overlay(alignment: .topLeading) { closeButton }
    }
}
