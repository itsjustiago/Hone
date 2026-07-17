import SwiftUI

/// The floating row of window previews shown on Dock hover.
struct WindowPeekView: View {
    /// Transparent margin around the card so the drop shadow (blur 18, y 8)
    /// isn't clipped by the hosting panel's bounds. The panel compensates for
    /// this inset when positioning, so it must stay in sync with the shadow.
    static let shadowInset: CGFloat = 32

    let appName: String
    let windows: [WindowInfo]
    let onSelect: (WindowInfo) -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            HStack(spacing: 10) {
                ForEach(windows) { window in
                    WindowCard(window: window) { onSelect(window) }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(Self.shadowInset)
        .onHover { onHoverChange($0) }
    }
}

private struct WindowCard: View {
    let window: WindowInfo
    let onSelect: () -> Void
    @State private var hovering = false

    private let thumbHeight: CGFloat = 128

    private var thumbWidth: CGFloat {
        let aspect = window.bounds.width / max(window.bounds.height, 1)
        return min(max(thumbHeight * aspect, 116), 280)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                thumbnail
                HStack(spacing: 4) {
                    if window.isMinimized {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    Text(window.title.isEmpty ? "Sem título" : window.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .frame(maxWidth: thumbWidth)
                .foregroundStyle(hovering ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let cg = window.thumbnail {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.gray.opacity(0.18))
                    Image(systemName: window.isMinimized ? "arrow.down.right.and.arrow.up.left" : "macwindow")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: thumbWidth, height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .saturation(window.isMinimized ? 0.7 : 1)
        .overlay(alignment: .topTrailing) {
            if window.isMinimized {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.orange, in: Circle())
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(hovering ? Color.accentColor : .white.opacity(0.12),
                              lineWidth: hovering ? 2 : 1)
        )
    }
}
