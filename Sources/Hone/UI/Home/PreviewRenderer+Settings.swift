import SwiftUI
import HoneDesign
import ClippyKit
import LidFoldKit
import ScreenlyKit
import SleepyKit
import SoundlyKit
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
            ("settings-windowsshortcuts", window("windowsShortcuts", off: off) {
                tool("windowsShortcuts", settings: AnyView(WindowsShortcutsSettingsView(module: WindowsShortcutsModule())))
            }),
            ("settings-island", window("island", off: off) {
                tool("island", settings: AnyView(IslandSettingsView(module: IslandModule())))
            }),
            ("settings-lidfold", window("lidFold", off: off) {
                tool("lidFold", settings: lidFoldSettings(status: .running, hasScreenAccess: true))
            }),
            // No lid sensor and no Screen Recording: the long status line and the grant button.
            ("settings-lidfold-alert", window("lidFold", off: off) {
                tool("lidFold", settings: lidFoldSettings(status: .unsupported, hasScreenAccess: false))
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
                tool("sleepy", mood: .asleep, enabled: false,
                     status: .off, ownIcon: false,
                     settings: SleepyPreview.settings())
            }),
            // On in Hone, but not blocking sleep: the switch is on, the mascot stays awake.
            ("settings-sleepy-on", window("sleepy", off: off.subtracting(["sleepy"])) {
                tool("sleepy",
                     status: .on(ToolLiveState(isActive: false, text: "sleep normal"), tint: VibeToolColor.sleepy),
                     ownIcon: false, settings: SleepyPreview.settings())
            }),
            ("settings-sleepy-awake", window("sleepy", off: off.subtracting(["sleepy"])) {
                tool("sleepy",
                     status: .on(ToolLiveState(isActive: true, text: "Mac e ecrã acordados"),
                                 tint: VibeToolColor.sleepy),
                     ownIcon: false, settings: SleepyPreview.settings())
            }),
            ("settings-stats", window("stats", off: off) {
                tool("stats", ownIcon: true, settings: StatsPreview.settings())
            }),
            ("settings-soundly", window("soundly", off: off) {
                tool("soundly", ownIcon: true, settings: SoundlyPreview.settings())
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
    private static func window<Detail: View>(_ selected: String, off: Set<String>,
                                             height: CGFloat = 900,
                                             @ViewBuilder detail: () -> Detail) -> AnyView {
        let entries = Fixture.all.map { spec -> SettingsEntry in
            let active = spec.momentary || !off.contains(spec.id)
            let isApp = spec.panel || spec.momentary
            let mood: Blob.Mood = active ? .awake : .asleep
            return SettingsEntry(id: spec.id, title: spec.title,
                                 leading: isApp ? .blob(spec.tint, mood) : .tweak(spec.icon, spec.tint),
                                 isActive: active, isApp: isApp)
        }
        return AnyView(
            SettingsShell(tools: entries, selection: .constant(selected), height: height, detail: detail)
                .environment(\.settingsPageScrolls, false))
    }

    private static func tool(_ id: String, mood: Blob.Mood = .awake, enabled: Bool = true,
                             status: VibeHeaderStatus? = nil, banners: [ToolPageBanner] = [], permission: ToolPagePermission? = nil,
                             ownIcon: Bool? = nil, settings: AnyView) -> some View {
        let spec = Fixture.all.first { $0.id == id }!
        return ToolPage(title: spec.title, summary: spec.tagline, tint: spec.tint, mood: mood,
                        symbol: spec.panel || spec.momentary ? nil : spec.icon,
                        status: status, banners: banners, dimmed: !enabled, settings: settings, permission: permission,
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

    /// The Lid Fold pane from fake values: no controller, so nothing starts.
    /// The scratch defaults suite is only read, never written.
    private static func lidFoldSettings(status: LidFoldController.Status, hasScreenAccess: Bool) -> AnyView {
        let defaults = UserDefaults(suiteName: "com.tiagof.hone.preview.lidfold") ?? .standard
        return AnyView(LidFoldSettingsContent(
            settings: LidFoldSettings(defaults: defaults), tint: VibeToolColor.lidFold, isEnabled: true,
            status: status, hasScreenAccess: hasScreenAccess, test: {}, requestScreenAccess: {}))
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
