import SwiftUI

/// The floating card shown while the keyboard is locked: a keyboard badge and the
/// status text on the left, a square unlock button on the right. It floats in the
/// centre of the screen over whatever is there — nothing gets covered.
struct CleanKeyboardOverlayView: View {
    var tint: Color
    var onUnlock: () -> Void

    /// Generous transparent margin so neither shadow layer is clipped by the panel.
    private let shadowRoom: CGFloat = 46

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 18) {
            iconBadge

            VStack(alignment: .leading, spacing: 4) {
                Text("Teclado bloqueado")
                    .font(.system(size: 17, weight: .semibold))
                Text("Carrega Esc 3× ou clica em Desbloquear")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 22)

            UnlockButton(tint: tint, action: onUnlock)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            // Light-from-above hairline: brighter on top, fading down.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        .compositingGroup()
        // Two-layer shadow: a soft ambient cast plus a tight contact shadow.
        .shadow(color: .black.opacity(0.3), radius: 30, y: 18)
        .shadow(color: .black.opacity(0.13), radius: 6, y: 2)
        .padding(shadowRoom)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { appeared = true }
        }
    }

    /// The app-style keyboard squircle with a small lock badge, so the "locked"
    /// state reads at a glance.
    private var iconBadge: some View {
        ModuleIcon(systemName: "keyboard.fill", tint: tint, size: 46)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(4)
                    .background(.white, in: Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.06)))
                    .offset(x: 5, y: 5)
            }
    }
}

/// The square "Desbloquear" tile. No keyboard shortcut on purpose — the keys are
/// blocked, so it has to be reachable with the mouse.
private struct UnlockButton: View {
    let tint: Color
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 23, weight: .semibold))
                Text("Desbloquear")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 90, height: 90)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(tint.gradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .shadow(color: tint.opacity(hovering ? 0.5 : 0.34),
                    radius: hovering ? 13 : 9, y: 4)
            .brightness(hovering ? 0.05 : 0)
            .scaleEffect(pressed ? 0.95 : (hovering ? 1.03 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .animation(.easeOut(duration: 0.13), value: hovering)
        .animation(.easeOut(duration: 0.1), value: pressed)
    }
}
