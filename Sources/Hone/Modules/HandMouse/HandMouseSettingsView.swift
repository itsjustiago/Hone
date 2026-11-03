import SwiftUI
import HandKit
import HoneDesign

struct HandMouseSettingsView: View {
    @Bindable var module: HandMouseModule
    /// Cameras connected right now, read when the page appears.
    @State private var cameras = HandTracker.availableCameras()
    /// The preview renders can't draw the AppKit anchor of a menu.
    @Environment(\.settingsPageScrolls) private var scrolls

    var body: some View {
        @Bindable var settings = module.settings
        let controller = module.controller
        let tint = module.tint
        let config = settings.config

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Atalho") {
                SettingsRow(title: "Ligar e desligar",
                            subtitle: "Carrega para ligar a câmara e outra vez para a desligar.") {
                    HandShortcutRecorder(shortcut: $settings.shortcut,
                                         onRecordingChange: { module.setShortcutCapture($0) })
                }
                RowDivider()
                SettingsRow(title: "Agora", subtitle: statusText(controller)) {
                    Button(controller.isTracking ? "Desligar" : "Ligar") { controller.toggle() }
                        .buttonStyle(VibeButtonStyle(prominent: !controller.isTracking, tint: tint))
                        .disabled(controller.calibration != nil || controller.isStarting)
                }
                if let problem = module.shortcutError ?? controller.error {
                    RowDivider()
                    VibeStatusLine(problem, color: VibeColor.danger, wraps: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }

            SettingsSection(title: "Câmara") {
                SettingsRow(title: "Câmara") {
                    VibeMenuPicker("Câmara", selection: cameraBinding(settings),
                                   options: cameraOptions(settings), offscreen: !scrolls)
                }
                RowDivider()
                ToggleRow(title: "Mostrar a câmara",
                          subtitle: "Uma janela pequena com a mão e a área ativa por cima. Desligado, a imagem não aparece.",
                          tint: tint, isOn: $settings.showCameraPreview)
                RowDivider()
                ToggleRow(title: "Mostrar o estado",
                          subtitle: "Uma etiqueta no fundo do ecrã com o modo e o último gesto.",
                          tint: tint, isOn: $settings.showHUD)
                RowDivider()
                SettingsRow(title: "Desligar sem mão",
                            subtitle: "A câmara desliga-se sozinha se não vir nenhuma mão.") {
                    VibeMenuPicker("Desligar sem mão", selection: $settings.autoOffMinutes,
                                   options: Self.autoOffOptions, offscreen: !scrolls)
                }
            }

            SettingsSection(title: "Calibração") {
                SettingsRow(title: "Área de movimento",
                            subtitle: "A zona da imagem que corresponde ao ecrã inteiro.") {
                    calibrationButton(.area, label: "Calibrar", controller: controller)
                }
                if config.shortcutGestures {
                    RowDivider()
                    SettingsRow(title: "Mão dos atalhos",
                                subtitle: config.ctrlPose == nil
                                    ? "Sem pose gravada, os atalhos só ligam ao fixá-los (polegar para cima 2 s)."
                                    : "Pose gravada. Os atalhos ligam com essa mão.") {
                        HStack(spacing: 8) {
                            if config.ctrlPose != nil && controller.calibration == nil {
                                Button("Esquecer pose") { controller.forgetShortcutPose() }
                                    .buttonStyle(VibeLinkButtonStyle(.secondary))
                            }
                            calibrationButton(.pose, label: "Gravar", controller: controller)
                        }
                    }
                }
                if controller.calibration != nil {
                    RowDivider()
                    VibeStatusLine("A calibrar: segue as instruções no ecrã. Esc cancela.",
                                   color: tint, wraps: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }

            SettingsSection(title: "Gestos") {
                ToggleRow(title: "Só observar",
                          subtitle: "Mostra os gestos no ecrã sem mexer em nada no Mac. Bom para experimentar.",
                          tint: tint, isOn: $settings.watchOnly)
                RowDivider()
                ToggleRow(title: "Gestos de janela",
                          subtitle: "Punho minimiza, mão deitada e fechada fecha, indicador e mindinho abrem o seletor.",
                          tint: tint, isOn: $settings.config.windowGestures)
                RowDivider()
                ToggleRow(title: "Gestos de atalhos",
                          subtitle: "Mão de lado: copiar, colar, desfazer, duplicar e Enter.",
                          tint: tint, isOn: $settings.config.shortcutGestures)
                RowDivider()
                tuneRow("Suavidade do cursor", "Mais alto: cursor mais estável, com um pouco de atraso.",
                        tint, settings, \.smoothing, 0.2...2.0, 0.8, inverted: true)
                RowDivider()
                tuneRow("Resposta rápida", "Mais alto: o cursor acompanha melhor os movimentos rápidos.",
                        tint, settings, \.responsiveness, 1...12, 6)
                RowDivider()
                SettingsRow(title: "Facilidade de clique",
                            subtitle: "Mais alto: o polegar não precisa de chegar tão perto do dedo.") {
                    slider("Facilidade de clique", tint, pinchBinding(settings), default: Self.fraction(0.30, 0.15...0.45))
                }
                RowDivider()
                tuneRow("Velocidade do scroll", "Quanto a página anda por cada movimento da mão.",
                        tint, settings, \.scrollGain, 1000...6000, 3000)
                RowDivider()
                tuneRow("Modo lento", "Mais alto: o cursor anda mais depressa com só o indicador esticado.",
                        tint, settings, \.fineSpeed, 0.1...0.6, 0.3)
                RowDivider()
                SettingsRow(title: "Repor gestos", subtitle: "Valores de fábrica. A calibração fica.") {
                    Button("Repor") { settings.resetGestures() }
                        .buttonStyle(VibeButtonStyle())
                }
            }

            SettingsSection(title: "Guia de gestos") {
                guide("Apontar", "Indicador esticado: o cursor segue a ponta do dedo.")
                RowDivider()
                guide("Clique", "Toca com o polegar no dedo do meio.")
                RowDivider()
                guide("Clique direito", "Dois toques, o segundo curto.")
                RowDivider()
                guide("Arrastar", "Toca e mantém; solta para largar.")
                RowDivider()
                guide("Scroll", "Dois toques, mantém o segundo e mexe a mão para cima e para baixo.")
                RowDivider()
                guide("Modo lento", "Só o indicador esticado; o polegar na base do indicador clica.")
                RowDivider()
                guide("Ecrã seguinte", "Toca com o polegar no mindinho.")
                RowDivider()
                guide("Congelar", "Polegar para cima: o cursor pára.")
                if config.windowGestures {
                    RowDivider()
                    guide("Minimizar", "Fecha o punho com o polegar escondido.")
                    RowDivider()
                    guide("Mão deitada", "Inclina a mão para a câmara e fecha os dedos meio segundo: fecha a janela.")
                    RowDivider()
                    guide("Seletor de janelas", "Sinal de rock (indicador, mindinho e polegar esticados) abre o Mission Control; aponta e abre a mão para escolher.")
                }
                if config.shortcutGestures {
                    RowDivider()
                    guide("Atalhos", "Põe a mão de lado como a gravaste. Mão aberta com o polegar fora é o ponto neutro.")
                    RowDivider()
                    guide("Copiar, colar, desfazer", "Mão aberta com o polegar escondido, só o indicador, só o mindinho.")
                    RowDivider()
                    guide("Duplicar e Enter", "Punho com o polegar para cima, e indicador e mindinho esticados.")
                    RowDivider()
                    guide("Fixar atalhos", "Polegar para cima durante 2 s; repete para soltar. Com os atalhos fixos, o rato normal mexe o cursor.")
                }
            }

            Label("Baseado no HandMouse de Misael Dias Santos (MIT). A imagem da câmara é processada no Mac e nunca é gravada nem enviada.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
        .onAppear { cameras = HandTracker.availableCameras() }
    }

    // MARK: Pieces

    private func statusText(_ controller: HandMouseController) -> String {
        if controller.isStarting { return "À espera da permissão da câmara." }
        if controller.calibration != nil { return "A calibrar." }
        return controller.isTracking ? "A seguir a tua mão." : "Desligado. A câmara só está ligada enquanto estiver ativo."
    }

    private func calibrationButton(_ kind: HandMouseController.Calibration, label: String,
                                   controller: HandMouseController) -> some View {
        Group {
            if controller.calibration == kind {
                Button("Cancelar") { controller.cancelCalibration() }
                    .buttonStyle(VibeButtonStyle())
            } else {
                Button(label) {
                    kind == .area ? controller.calibrateArea() : controller.recordShortcutPose()
                }
                .buttonStyle(VibeButtonStyle())
                .disabled(controller.calibration != nil || controller.isStarting)
            }
        }
    }

    private func guide(_ gesture: String, _ detail: String) -> some View {
        SettingsRow(title: gesture, subtitle: detail) { EmptyView() }
    }

    // MARK: Sliders

    /// Where `value` sits in `range`, 0…1. The slider works on that, so its
    /// VoiceOver value reads as a percentage whatever the setting's unit is.
    private static func fraction(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func slider(_ label: String, _ tint: Color, _ value: Binding<Double>, default def: Double) -> some View {
        VibeSlider(value: value, defaultValue: def, label: label, tint: tint)
            .frame(width: 190)
    }

    /// A row for one `HandConfig` number. `inverted`: the setting falls as the slider rises.
    private func tuneRow(_ title: String, _ subtitle: String, _ tint: Color, _ settings: HandMouseSettings,
                         _ key: WritableKeyPath<HandConfig, Double>, _ range: ClosedRange<Double>,
                         _ fallback: Double, inverted: Bool = false) -> some View {
        let toFraction: (Double) -> Double = { v in
            let f = Self.fraction(v, range)
            return inverted ? 1 - f : f
        }
        let binding = Binding<Double>(
            get: { min(max(toFraction(settings.config[keyPath: key]), 0), 1) },
            set: { f in
                let g = inverted ? 1 - f : f
                settings.config[keyPath: key] = range.lowerBound + g * (range.upperBound - range.lowerBound)
            })
        return SettingsRow(title: title, subtitle: subtitle) {
            slider(title, tint, binding, default: toFraction(fallback))
        }
    }

    /// Click pinch: `pinchOff` follows `pinchOn` at a fixed gap, so it can't be set apart.
    private func pinchBinding(_ settings: HandMouseSettings) -> Binding<Double> {
        let range = 0.15...0.45
        return Binding(
            get: { min(max(Self.fraction(settings.config.pinchOn, range), 0), 1) },
            set: { f in
                let on = range.lowerBound + f * (range.upperBound - range.lowerBound)
                settings.config.pinchOn = on
                settings.config.pinchOff = on + 0.10
            })
    }

    // MARK: Pickers

    /// "" stands for the system's default camera.
    private func cameraBinding(_ settings: HandMouseSettings) -> Binding<String> {
        Binding(get: { settings.cameraID ?? "" },
                set: { settings.cameraID = $0.isEmpty ? nil : $0 })
    }

    private func cameraOptions(_ settings: HandMouseSettings) -> [VibeMenuPicker<String>.Option] {
        var options = [VibeMenuPicker<String>.Option("", title: "Câmara predefinida", label: "Predefinida")]
        options += cameras.map { .init($0.id, title: $0.name, label: $0.name) }
        if let id = settings.cameraID, !cameras.contains(where: { $0.id == id }) {
            options.append(.init(id, title: "Câmara desligada", label: "Desligada"))
        }
        return options
    }

    private static let autoOffOptions: [VibeMenuPicker<Int>.Option] = [
        .init(0, title: "Nunca", label: "Nunca"),
        .init(1, title: "Após 1 minuto", label: "1 min"),
        .init(2, title: "Após 2 minutos", label: "2 min"),
        .init(5, title: "Após 5 minutos", label: "5 min"),
        .init(10, title: "Após 10 minutos", label: "10 min"),
    ]
}
