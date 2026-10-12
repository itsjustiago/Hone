import SwiftUI
import HoneDesign
import LidFoldKit

extension LidFoldController.Status {
    /// What the Test section says about the engine, in PT-PT.
    var message: String {
        switch self {
        case .stopped: return "Desligado"
        case .running: return "Pronto — fecha a tampa devagar"
        case .testing: return "A testar…"
        case .unsupported:
            return "Este Mac não tem sensor do ângulo da tampa (só MacBook Air M2+ e MacBook Pro 14\"/16\" M1 Pro+). O teste de \(LidFoldModule.testSeconds) s funciona na mesma."
        case .noMetal: return "Sem GPU Metal compatível"
        case .waitingForDisplay: return "À espera do ecrã interno"
        case .failed(let message): return message
        }
    }

    fileprivate func dotColor(tint: Color) -> Color {
        switch self {
        case .stopped: return VibeColor.dotOff
        case .running: return VibeColor.success
        case .testing: return tint
        case .unsupported, .waitingForDisplay: return VibeColor.warning
        case .noMetal, .failed: return VibeColor.danger
        }
    }
}

/// The live pane: reads the module and the Screen Recording permission, and hands
/// plain values to `LidFoldSettingsContent`.
struct LidFoldSettingsView: View {
    let module: LidFoldModule
    @State private var permissions = Permissions.shared

    var body: some View {
        LidFoldSettingsContent(
            settings: module.settings,
            tint: module.tint,
            isEnabled: module.isEnabled,
            status: module.status,
            hasScreenAccess: permissions.isScreenRecordingTrusted,
            test: { module.testNow() },
            requestScreenAccess: { permissions.requestScreenRecording() }
        )
    }
}

/// The pane itself, from plain values so the preview renderer can draw it
/// offscreen without a controller.
struct LidFoldSettingsContent: View {
    @Bindable var settings: LidFoldSettings
    let tint: Color
    let isEnabled: Bool
    let status: LidFoldController.Status
    let hasScreenAccess: Bool
    let test: () -> Void
    let requestScreenAccess: () -> Void

    private var canTest: Bool { isEnabled && status != .stopped && status != .testing }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Efeito") {
                effectGrid
            }

            SettingsSection(title: "Ecrã real") {
                ToggleRow(
                    title: "Usar o ecrã real",
                    subtitle: "Ligado, o macOS mostra o ícone roxo de gravação, mas só enquanto a tampa se mexe. Desligado, o ecrã só escurece (fade) e não precisa de permissão.",
                    tint: tint,
                    isOn: $settings.captureEnabled
                )
                RowDivider()
                SettingsRow(
                    title: "Gravação de Ecrã",
                    subtitle: hasScreenAccess ? "Permitido" : "Sem permissão — a usar fade"
                ) {
                    if hasScreenAccess {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(VibeColor.success)
                            .accessibilityLabel("Permitido")
                    } else {
                        Button("Conceder…", action: requestScreenAccess)
                    }
                }
            }

            SettingsSection(title: "Testar") {
                SettingsRow(
                    title: "Ver a animação",
                    subtitle: "Corre o efeito sem mexeres na tampa."
                ) {
                    Button("Testar \(LidFoldModule.testSeconds) s", action: test)
                        .disabled(!canTest)
                }
                RowDivider()
                VibeStatusLine(status.message, color: status.dotColor(tint: tint), wraps: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            Label("Não mexe no brilho nem na suspensão: o Sleepy continua a tratar do ecrã com a tampa fechada.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
    }

    /// Three pills a row; the chosen effect wears the tool's colour.
    private var effectGrid: some View {
        let effects = FoldEffect.allCases
        let rows = stride(from: 0, to: effects.count, by: 3).map { Array(effects[$0..<min($0 + 3, effects.count)]) }
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { effect in
                        EffectPill(effect: effect, isSelected: effect == settings.effect, tint: tint) {
                            settings.effect = effect
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// One choice of the effect picker: a 30 pt capsule with the effect's symbol and name.
private struct EffectPill: View {
    let effect: FoldEffect
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: effect.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? tint : VibeColor.text3)
                Text(effect.displayName)
                    .font(VibeFont.pill)
                    .foregroundStyle(isSelected || hovering ? VibeColor.text1 : VibeColor.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: VibeMetrics.pillHeight)
            .background(fill, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(border, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(VibePressStyle())
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .animation(VibeMotion.standard, value: isSelected)
        .accessibilityLabel(effect.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return tint.vibeMix(over: VibeColor.card, amount: 0.14) }
        return hovering ? VibeColor.raised : VibeColor.inset
    }

    private var border: Color {
        isSelected ? tint.vibeMix(over: VibeColor.card, amount: 0.55) : VibeColor.cardBorder
    }
}
