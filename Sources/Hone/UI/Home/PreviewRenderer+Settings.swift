import SwiftUI
import HoneDesign
import ClippyKit
import ScreenlyKit
import SleepyKit
import StatsKit

extension PreviewRenderer {
    /// Renders of the Settings window and the onboarding, from fake data and the
    /// Kits' own settings views. The live pages feed the same views from the
    /// real modules, so what shows here is what the window draws.
    static var settingsPages: [(String, AnyView)] {
        let off: Set<String> = ["windowPeek", "quitOnClose", "sleepy"]
        let accessibility = ToolPagePermission(
            title: "Acessibilidade", purpose: "Para ver o atalho e colar no sítio certo.",
            isGranted: true, request: {})
        let accessibilityMissing = ToolPagePermission(
            title: "Acessibilidade", purpose: "Para ver o atalho e colar no sítio certo.",
            isGranted: false, request: {})
        let needsAccessibility = ToolPageBanner(
            id: "accessibility", color: VibeColor.danger, title: "Falta acesso de Acessibilidade",
            detail: "O Hone precisa dele para esta ferramenta funcionar.",
            actionTitle: "Abrir Definições…", action: {})

        return [
            ("settings-scroll", window("scroll", off: off) {
                tool("scroll", settings: AnyView(ScrollSettingsView(module: ScrollModule())))
            }),
            ("settings-alttab", window("altTab", off: off) {
                tool("altTab", settings: AnyView(AltTabSettingsView(module: AltTabModule())))
            }),
            ("settings-keyswap", window("keySwap", off: off) {
                tool("keySwap", settings: AnyView(KeySwapSettingsView(module: KeySwapModule())))
            }),
            ("settings-quitonclose", window("quitOnClose", off: off) {
                tool("quitOnClose", mood: .asleep, enabled: false,
                     settings: AnyView(QuitOnCloseSettingsView(module: QuitOnCloseModule())))
            }),
            ("settings-windowpeek", window("windowPeek", off: off) {
                tool("windowPeek", mood: .asleep, enabled: false,
                     settings: AnyView(WindowPeekSettingsView(module: WindowPeekModule())))
            }),
            ("settings-cleankeyboard", window("cleanKeyboard", off: off) {
                tool("cleanKeyboard", settings: AnyView(CleanKeyboardSettingsView(module: CleanKeyboardModule())))
            }),
            ("settings-clippy", window("clippy", off: off) {
                tool("clippy", permission: accessibility, ownIcon: true, settings: ClippyPreview.settings())
            }),
            ("settings-clippy-alert", window("clippy", off: off) {
                tool("clippy", mood: .alert, banners: [needsAccessibility], permission: accessibilityMissing,
                     ownIcon: false, settings: ClippyPreview.settings())
            }),
            ("settings-screenly", window("screenly", off: off) {
                tool("screenly", ownIcon: true, settings: ScreenlyPreview.settings())
            }),
            ("settings-sleepy-off", window("sleepy", off: off) {
                tool("sleepy", mood: .asleep, enabled: false, ownIcon: false, settings: SleepyPreview.settings())
            }),
            ("settings-stats", window("stats", off: off) {
                tool("stats", ownIcon: true, settings: StatsPreview.settings())
            }),
            ("settings-general", window("general", off: off) {
                GeneralSettingsView(updateChecker: UpdateChecker())
            }),
            ("onboarding", onboarding(.missing)),
            ("onboarding-granted", onboarding(.granted)),
        ]
    }

    /// The window: the sidebar as the live one builds it, `detail` on the right. Tall by
    /// default, with the pages laid out whole, so one image shows a page end to end.
    private static func window<Detail: View>(_ selected: String, off: Set<String>, height: CGFloat = 900,
                                             @ViewBuilder detail: () -> Detail) -> AnyView {
        let entries = Fixture.all.map { spec -> SettingsEntry in
            let active = spec.momentary || !off.contains(spec.id)
            return SettingsEntry(id: spec.id, title: spec.title,
                                 leading: .blob(spec.tint, active ? .awake : .asleep), isActive: active)
        }
        return AnyView(
            SettingsShell(tools: entries, selection: .constant(selected), height: height, detail: detail)
                .environment(\.settingsPageScrolls, false))
    }

    private static func tool(_ id: String, mood: Blob.Mood = .awake, enabled: Bool = true,
                             banners: [ToolPageBanner] = [], permission: ToolPagePermission? = nil,
                             ownIcon: Bool? = nil, settings: AnyView) -> some View {
        let spec = Fixture.all.first { $0.id == id }!
        return ToolPage(title: spec.title, summary: spec.tagline, tint: spec.tint, mood: mood,
                        banners: banners, dimmed: !enabled, settings: settings, permission: permission,
                        ownIcon: ownIcon.map { Binding.constant($0) }) {
            if spec.momentary {
                Button(spec.actionLabel) {}
                    .buttonStyle(VibeButtonStyle(prominent: true, tint: spec.tint))
                    .controlSize(.large)
            } else {
                Toggle("Ligar \(spec.title)", isOn: .constant(enabled))
                    .labelsHidden()
                    .toggleStyle(VibeToggleStyle(tint: spec.tint))
            }
        }
    }

    private static func onboarding(_ accessibility: OnboardingAccessibility) -> AnyView {
        AnyView(OnboardingContent(
            tools: Fixture.all.map {
                OnboardingTool(id: $0.id, name: $0.shortTitle, summary: $0.tagline, tint: $0.tint,
                               isAvailable: true)
            },
            accessibility: accessibility))
    }
}
