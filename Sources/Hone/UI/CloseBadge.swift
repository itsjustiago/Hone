import SwiftUI

/// The close affordance that sits on a window preview — in the corner the red
/// button lives in on a real window. Shared by the switcher and the Dock peek so
/// closing a window looks and behaves the same wherever a preview is shown.
///
/// It stays invisible (and unclickable, so the preview underneath keeps taking
/// the click) until the card holding it is hovered, and turns the traffic-light
/// red of the button it stands for once the pointer is on the disc itself — the
/// destructive action announcing itself before the click.
struct CloseBadge: View {
    /// Revealed only while the card under it is hovered.
    let visible: Bool
    let action: () -> Void

    @State private var hovering = false

    /// The macOS close-button red, so the affordance reads as the red dot itself.
    private static let closeRed = Color(red: 1, green: 0.37, blue: 0.34)

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                // Dark disc with a hairline rim: legible over a bright thumbnail
                // and over the grey icon placeholder alike.
                .background(hovering ? Self.closeRed : .black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(6)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.82)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.12), value: visible)
        .animation(.easeOut(duration: 0.12), value: hovering)
        // The pointer can leave the card without ever leaving the disc (the card
        // shrinks away under it), so drop the red with the badge itself.
        .onChange(of: visible) { _, shown in if !shown { hovering = false } }
        .help("Fechar janela")
    }
}
