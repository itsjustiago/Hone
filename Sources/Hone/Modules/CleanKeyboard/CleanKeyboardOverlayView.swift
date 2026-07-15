import SwiftUI

/// Live countdown state shared by every overlay panel (one per screen), so all
/// screens tick down together.
@MainActor
@Observable
final class CleanKeyboardOverlayState {
    var total: Int
    var remaining: Int

    init(total: Int) {
        self.total = max(total, 1)
        self.remaining = max(total, 1)
    }

    var progress: Double {
        guard total > 0 else { return 0 }
        return Double(remaining) / Double(total)
    }

    var clock: String {
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// The full-screen "keyboard is locked" curtain: a dimmed scrim over a centred
/// card with a countdown ring and the two ways out (Esc ×3, or the button).
struct CleanKeyboardOverlayView: View {
    @Bindable var state: CleanKeyboardOverlayState
    var tint: Color
    var onUnlock: () -> Void

    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                icon

                VStack(spacing: 7) {
                    Text("Teclado bloqueado")
                        .font(.system(size: 26, weight: .bold))
                    Text("Limpa as teclas à vontade — estão desativadas.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                countdown
                    .padding(.top, 4)

                VStack(spacing: 14) {
                    // No keyboard shortcut here on purpose: the keys are blocked,
                    // so this must be reachable with the mouse.
                    Button(action: onUnlock) {
                        Text("Desbloquear")
                            .font(.headline)
                            .frame(minWidth: 150)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)

                    Label("ou carrega **Esc** três vezes", systemImage: "escape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            .padding(48)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        }
        .onAppear { pulse = true }
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 82, height: 82)
                .shadow(color: tint.opacity(0.45), radius: 18, y: 8)
            Image(systemName: "keyboard.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
            // Small lock badge, bottom-trailing.
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .padding(5)
                .background(.white, in: Circle())
                .offset(x: 32, y: 32)
        }
        .scaleEffect(pulse ? 1.04 : 0.98)
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
    }

    private var countdown: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.12), lineWidth: 7)
            Circle()
                .trim(from: 0, to: state.progress)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: state.progress)
            VStack(spacing: 0) {
                Text(state.clock)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text("automático")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 118, height: 118)
        .animation(.snappy, value: state.remaining)
    }
}
