import SwiftUI
import AppKit

/// First-run welcome window: introduces the tools and the Accessibility
/// permission. Ported from Clippy's onboarding, reusing Hone's `ModuleIcon`.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(manager: ModuleManager) {
        if window == nil { build(manager: manager) }
        // Defer and force front — an accessory app won't present a window reliably
        // during launch otherwise.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.center()
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    private func build(manager: ModuleManager) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.title = "Hone"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(
            rootView: OnboardingView(manager: manager, onClose: { [weak self] in self?.window?.close() }))
        window = w
    }
}

struct OnboardingView: View {
    @Bindable var manager: ModuleManager
    var onClose: () -> Void
    @State private var permissions = Permissions.shared

    private var needsAccessibility: Bool {
        manager.modules.contains { $0.requiresAccessibility } && !permissions.isAccessibilityTrusted
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: .accentColor.opacity(0.35), radius: 8, y: 4)
                Text("Bem-vindo ao Hone")
                    .font(.system(size: 22, weight: .bold))
                Text("Uma caixa de ferramentas para o teu Mac.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(manager.modules, id: \.id) { module in
                    featureRow(module: module)
                }
                if needsAccessibility {
                    accessibilityCard
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 16)

            Button(action: onClose) {
                Text("Começar").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 28)
            .padding(.bottom, 26)
        }
        .frame(width: 460, height: 480)
    }

    private func featureRow(module: any HoneModule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ModuleIcon(systemName: module.iconSystemName, tint: module.tint, size: 30)
                .saturation(module.isAvailable ? 1 : 0)
                .opacity(module.isAvailable ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 4) {
                Text(module.title).font(.system(size: 14, weight: .semibold))
                Text(module.isAvailable ? module.summary : "Em breve.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var accessibilityCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permissions.isAccessibilityTrusted ? "checkmark.circle.fill" : "hand.raised.fill")
                .font(.system(size: 20))
                .foregroundStyle(permissions.isAccessibilityTrusted ? .green : .orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(permissions.isAccessibilityTrusted ? "Acessibilidade ativa" : "Ativar Acessibilidade")
                    .font(.system(size: 14, weight: .semibold))
                Text(permissions.isAccessibilityTrusted
                     ? "Está tudo pronto — as ferramentas já podem trabalhar."
                     : "O Hone precisa dela para controlar o scroll e espreitar janelas.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !permissions.isAccessibilityTrusted {
                    Button("Conceder acesso…") { permissions.requestAccessibility() }
                        .controlSize(.small)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            (permissions.isAccessibilityTrusted ? Color.green : Color.orange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder((permissions.isAccessibilityTrusted ? Color.green : Color.orange).opacity(0.22))
        )
        .animation(.easeInOut(duration: 0.2), value: permissions.isAccessibilityTrusted)
    }
}
