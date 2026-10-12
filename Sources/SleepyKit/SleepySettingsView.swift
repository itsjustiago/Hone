import SwiftUI
import AppKit
import HoneDesign

/// Observable settings state, mirrored from the system each time the pane appears.
final class SettingsModel: ObservableObject {
    @Published var passwordless = PrivilegedAccess.isInstalled
    @Published var autoOffMinutes = SleepController.autoOffMinutes
    @Published var batteryThreshold = SleepController.batteryThreshold
    @Published var sleepMode = SettingsModel.shownMode()
    @Published var endAction = SleepController.endAction
    @Published var lowPowerWhenLidClosed = LidExtras.lowPowerWhenLidClosed
    @Published var muteWhenLidClosed = LidExtras.muteWhenLidClosed
    @Published var stayAwakeForRemoteSessions = SleepController.stayAwakeForRemoteSessions
    /// A regra sudoers instalada deixa ligar o Low Power Mode? `nil` = ainda não
    /// se sabe (ou o toggle está desligado e não interessa).
    @Published var lowPowerRuleAllowed: Bool?

    func refresh() {
        passwordless = PrivilegedAccess.isInstalled
        autoOffMinutes = SleepController.autoOffMinutes
        batteryThreshold = SleepController.batteryThreshold
        sleepMode = Self.shownMode()
        endAction = SleepController.endAction
        lowPowerWhenLidClosed = LidExtras.lowPowerWhenLidClosed
        muteWhenLidClosed = LidExtras.muteWhenLidClosed
        stayAwakeForRemoteSessions = SleepController.stayAwakeForRemoteSessions
    }

    /// Com o Sleepy ligado, o modo em uso (como o painel): numa sessão do gatilho
    /// pode não ser o guardado. Escolher um grava a preferência e limpa esse modo
    /// só da sessão (`setSleepMode`).
    static func shownMode() -> SleepMode {
        SleepController.shared.isActive ? SleepController.shared.activeMode : SleepController.sleepMode
    }

    /// Volta a ler a regra sudoers (`sudo -n -l`, fora do main). Só com o toggle
    /// ligado: é aí que a falta dela importa.
    func refreshLowPowerRule() {
        guard lowPowerWhenLidClosed else {
            lowPowerRuleAllowed = nil
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let allowed = PrivilegedAccess.allowsLowPowerMode()
            DispatchQueue.main.async {
                guard let self, self.lowPowerWhenLidClosed else { return }
                self.lowPowerRuleAllowed = allowed
            }
        }
    }

    /// Instala a regra v2 (pede admin uma vez) e volta a verificar.
    func updateRule() {
        _ = PrivilegedAccess.install()
        passwordless = PrivilegedAccess.isInstalled
        refreshLowPowerRule()
    }
}

/// Sleepy's settings, without the app-level sections (launch at login, menu-bar
/// icon, updates, version) — Hone owns those and embeds this in its own window.
struct SleepySettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Impedir sleep") {
                SettingsRow(
                    title: "Com a tampa fechada",
                    subtitle: "Fica acordado: o Mac continua a trabalhar com a tampa fechada (precisa da password de admin). Adormece: só fica acordado com a tampa aberta."
                ) {
                    Picker("", selection: Binding(
                        get: { model.sleepMode },
                        set: { mode in
                            // Recusada (prompt de admin cancelado), o refresh faz o picker recuar.
                            SleepController.shared.setSleepMode(mode)
                            model.refresh()
                        })) {
                        ForEach(SleepMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                RowDivider()
                ToggleRow(
                    title: "Não pedir password",
                    subtitle: "Instala uma regra restrita (só pmset disablesleep e lowpowermode). Pede admin uma vez.",
                    isOn: Binding(
                        get: { model.passwordless },
                        set: { on in
                            _ = on ? PrivilegedAccess.install() : PrivilegedAccess.uninstall()
                            model.passwordless = PrivilegedAccess.isInstalled
                        }))
                RowDivider()
                lidExtrasRows
                RowDivider()
                ToggleRow(
                    title: "Ficar acordado durante sessões remotas",
                    subtitle: remoteSubtitle,
                    isOn: Binding(
                        get: { model.stayAwakeForRemoteSessions },
                        set: { on in
                            model.stayAwakeForRemoteSessions = on
                            SleepController.stayAwakeForRemoteSessions = on
                        }))
                RowDivider()
                SettingsRow(
                    title: "Desligar sozinho",
                    subtitle: "O ecrã e o Mac voltam ao normal ao fim deste tempo. De tampa fechada, adormece logo."
                ) {
                    Picker("", selection: Binding(
                        get: { model.autoOffMinutes },
                        set: { model.autoOffMinutes = $0; SleepController.autoOffMinutes = $0 })) {
                        ForEach(SleepController.autoOffOptions) { Text($0.title).tag($0.minutes) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                RowDivider()
                SettingsRow(
                    title: "Desligar com bateria a",
                    subtitle: "Só em bateria. O Sleepy desliga-se e, com a tampa fechada, o Mac adormece."
                ) {
                    Picker("", selection: Binding(
                        get: { model.batteryThreshold },
                        set: { model.batteryThreshold = $0; SleepController.batteryThreshold = $0 })) {
                        ForEach(SleepController.batteryOptions) { Text($0.title).tag($0.percent) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                RowDivider()
                SettingsRow(
                    title: "Quando desligar sozinho",
                    subtitle: "Com a tampa fechada sem ecrã externo, o Mac dorme sempre."
                ) {
                    Picker("", selection: Binding(
                        get: { model.endAction },
                        set: { model.endAction = $0; SleepController.endAction = $0 })) {
                        ForEach(EndAction.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
        }
        .onAppear {
            model.refresh()
            model.refreshLowPowerRule()
        }
    }

    // MARK: - Sessões remotas

    private static let remoteNote = "Liga sozinho com um Terminal por SSH ou a Partilha de Ecrã e desliga quando a sessão acaba; scp, rsync e ssh host cmd não contam."

    /// Sem a regra sem password não há «Fica acordado» sem ninguém ao ecrã: a sessão
    /// só segura o ecrã (e a tampa fechada adormece o Mac). Diz-se, para não surpreender.
    /// Conta o modo guardado: o picker pode estar a mostrar o só ecrã da sessão.
    private var remoteSubtitle: String {
        guard model.stayAwakeForRemoteSessions, SleepController.sleepMode.usesDisableSleep, !model.passwordless
        else { return Self.remoteNote }
        return Self.remoteNote + " Sem «Não pedir password», só o ecrã fica acordado."
    }

    // MARK: - Tampa fechada: extras

    /// Só valem em "Fica acordado" com a tampa fechada sem ecrã externo: em
    /// "Adormece" o Mac dorme e não há nada para poupar ou calar.
    private var extrasDisabled: Bool { model.sleepMode == .displayOnly }

    private static let extrasNote = "Só em «Fica acordado»: em «Adormece» o Mac dorme de tampa fechada."

    @ViewBuilder
    private var lidExtrasRows: some View {
        ToggleRow(
            title: "Low Power Mode com a tampa fechada",
            subtitle: extrasDisabled ? Self.extrasNote : "Poupa bateria enquanto o Mac trabalha de tampa fechada.",
            isOn: Binding(
                get: { model.lowPowerWhenLidClosed },
                set: { on in
                    model.lowPowerWhenLidClosed = on
                    LidExtras.lowPowerWhenLidClosed = on
                    model.refreshLowPowerRule()
                }))
            .disabled(extrasDisabled)
            .opacity(extrasDisabled ? 0.45 : 1)
        if model.lowPowerWhenLidClosed, !extrasDisabled, model.lowPowerRuleAllowed == false {
            RowDivider()
            let notice = PrivilegedAccess.lowPowerRuleNotice(installed: model.passwordless)
            SettingsRow(title: notice.title, subtitle: notice.detail) {
                Button(PrivilegedAccess.ruleButtonTitle(installed: model.passwordless)) { model.updateRule() }
                    .buttonStyle(VibeButtonStyle())
                    .controlSize(.small)
            }
        }
        RowDivider()
        ToggleRow(
            title: "Silenciar com a tampa fechada",
            subtitle: extrasDisabled ? Self.extrasNote : "O som volta quando abres a tampa.",
            isOn: Binding(
                get: { model.muteWhenLidClosed },
                set: { on in
                    model.muteWhenLidClosed = on
                    LidExtras.muteWhenLidClosed = on
                }))
            .disabled(extrasDisabled)
            .opacity(extrasDisabled ? 0.45 : 1)
    }
}
