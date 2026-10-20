import SwiftUI

/// Stats' settings, without the app-level sections (launch at login, menu-bar
/// icon, updates) — Hone owns those and embeds this in its own window.
struct StatsSettingsView: View {
    @ObservedObject var settings: StatsSettings
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Métricas") {
                ForEach(Array(Metric.allCases.enumerated()), id: \.element) { index, metric in
                    if index > 0 { RowDivider() }
                    let note = monitor.unavailable[metric]
                    ToggleRow(
                        title: metric.title,
                        subtitle: note,
                        isOn: Binding(
                            get: { note == nil && settings.enabledMetrics.contains(metric) },
                            set: { settings.setEnabled(metric, $0) }))
                    .disabled(note != nil)
                }
            }
            SettingsSection(title: "Aspeto") {
                ToggleRow(title: "Mostrar etiquetas",
                          subtitle: "O nome da métrica (CPU, RAM…) por cima de cada valor. Desligadas, cada valor leva um símbolo.",
                          isOn: $settings.showLabels)
                RowDivider()
                ToggleRow(title: "Colorir pela carga",
                          subtitle: "Laranja a partir de 60% e vermelho a partir de 85%. A memória segue a pressão; a temperatura muda aos 85 °C e aos 95 °C.",
                          isOn: $settings.colorByLoad)
                RowDivider()
                SettingsRow(title: "Atualizar a cada", subtitle: "Intervalos mais curtos gastam um pouco mais de bateria.") {
                    Picker("Atualizar a cada", selection: $settings.interval) {
                        ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }
        }
        .onAppear { if !monitor.isRunning { monitor.probeAvailability() } }
    }
}
