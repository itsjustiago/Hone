import SwiftUI
import AppKit
import HoneDesign

/// First-run welcome window: introduces the tools and the Accessibility
/// permission, in the same black-and-mascots look as the popover.
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
        let size = OnboardingContent.size
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.title = "Hone"
        // Black like the popover, whatever the system appearance is.
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(VibeColor.canvas)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(
            rootView: OnboardingView(manager: manager, onClose: { [weak self] in self?.window?.close() }))
        window = w
    }
}

/// The live welcome: bridges the manager and the permission state to
/// `OnboardingContent`.
struct OnboardingView: View {
    @Bindable var manager: ModuleManager
    var onClose: () -> Void
    @State private var permissions = Permissions.shared

    var body: some View {
        OnboardingContent(
            tools: manager.modules.map {
                OnboardingTool(id: $0.id, name: $0.shortTitle,
                               summary: $0.isAvailable ? $0.summary : "Em breve.",
                               tint: $0.tint, isAvailable: $0.isAvailable)
            },
            accessibility: manager.modules.contains { $0.requiresAccessibility }
                ? (permissions.isAccessibilityTrusted ? .granted : .missing)
                : nil,
            grantAccessibility: { permissions.requestAccessibility() },
            start: onClose)
    }
}

// MARK: - Content

struct OnboardingTool: Identifiable {
    let id: String
    let name: String
    let summary: String
    let tint: Color
    let isAvailable: Bool
}

enum OnboardingAccessibility {
    case missing, granted
}

/// Plain values in, closures out, so the preview renderer can draw it offscreen.
struct OnboardingContent: View {
    static let size = CGSize(width: 460, height: 500)

    let tools: [OnboardingTool]
    let accessibility: OnboardingAccessibility?
    var grantAccessibility: () -> Void = {}
    var start: () -> Void = {}

    var body: some View {
        VStack(spacing: VibeSpacing.cardGap) {
            hero
            toolsCard
            if let accessibility { accessibilityBanner(accessibility) }
            Spacer(minLength: 0)
            Button(action: start) {
                Text("Começar").frame(maxWidth: .infinity)
            }
            .buttonStyle(VibeButtonStyle(prominent: true))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        // Clear of the window buttons: the content runs under the title bar.
        .padding(.top, 44)
        .padding(.bottom, 16)
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
        .vibePanelBackground()
        .animation(VibeMotion.standard, value: accessibility == .granted)
    }

    private var hero: some View {
        HStack(spacing: 18) {
            Blob(color: VibePalette.white, mood: .awake, height: 54, glow: true)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text("Bem-vindo ao Hone")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(VibeColor.text1)
                Text("Uma caixa de ferramentas para o teu Mac.")
                    .font(VibeFont.subtitle)
                    .foregroundStyle(VibeColor.text3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .vibeCard()
    }

    /// Two columns of pills, as on the home.
    private var toolsCard: some View {
        let rows = stride(from: 0, to: tools.count, by: 2).map { Array(tools[$0..<min($0 + 2, tools.count)]) }
        return VStack(alignment: .leading, spacing: 10) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(rows, id: \.first?.id) { row in
                    GridRow {
                        ForEach(row) { ToolChip(tool: $0) }
                        if row.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
            Text("Liga e desliga cada uma a partir do menu do Hone.")
                .font(VibeFont.caption)
                .foregroundStyle(VibeColor.text4)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vibeCard(padding: 8)
    }

    private func accessibilityBanner(_ state: OnboardingAccessibility) -> some View {
        switch state {
        case .missing:
            return VibeBanner(color: VibeColor.danger, title: "Ativar Acessibilidade",
                              detail: "O Hone precisa dela para controlar o scroll e espreitar janelas.",
                              actionTitle: "Conceder acesso…", action: grantAccessibility)
        case .granted:
            return VibeBanner(color: VibeColor.success, title: "Acessibilidade ativa",
                              detail: "Está tudo pronto — as ferramentas já podem trabalhar.")
        }
    }
}

/// A tool as a pill: its mascot and name. The tooltip tells what it does.
private struct ToolChip: View {
    let tool: OnboardingTool

    private let blobHeight: CGFloat = 19

    var body: some View {
        Text(tool.name)
            .font(VibeFont.pill)
            .foregroundStyle(tool.isAvailable ? VibeColor.text2 : VibeColor.text4)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.leading, 6 + blobHeight * 1.3 + 4)
            .padding(.trailing, 12)
            .frame(height: VibeMetrics.pillHeight)
            .overlay(alignment: .leading) {
                Blob(color: tool.tint, mood: tool.isAvailable ? .awake : .asleep, height: blobHeight)
                    .padding(.leading, 6)
            }
            .background(VibeColor.inset, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(VibeColor.cardBorder, lineWidth: 1))
            .help(tool.summary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(tool.name): \(tool.summary)")
    }
}
