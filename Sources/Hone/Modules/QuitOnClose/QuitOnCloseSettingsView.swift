import AppKit
import SwiftUI
import HoneDesign
import UniformTypeIdentifiers

struct QuitOnCloseSettingsView: View {
    @Bindable var module: QuitOnCloseModule
    @State private var permissions = Permissions.shared

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Comportamento") {
                SettingsRow(
                    title: "Sair ao fechar",
                    subtitle: "Escolhe se a regra vale para todas as apps (com exceções) ou só para as que indicares."
                ) {
                    Picker("", selection: $settings.mode) {
                        ForEach(QuitOnCloseMode.allCases) { mode in
                            Text(mode.display).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                RowDivider()

                SettingsRow(
                    title: "Esperar antes de sair",
                    subtitle: "A contagem começa quando fechas a última janela. Se abrires outra antes do tempo acabar, a app fica."
                ) {
                    Picker("", selection: $settings.delaySeconds) {
                        ForEach(settings.delayChoices, id: \.self) { seconds in
                            Text(QuitOnCloseSettings.delayLabel(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }
            }

            SettingsSection(title: settings.mode == .allExcept ? "Exceções" : "Apps") {
                if settings.listedBundleIDs.isEmpty {
                    Text(emptyMessage(for: settings.mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    RowDivider()
                } else {
                    ForEach(settings.listedBundleIDs, id: \.self) { bundleID in
                        appRow(bundleID: bundleID, tint: tint)
                        RowDivider()
                    }
                }

                HStack {
                    Button("Adicionar app…") { addApps() }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            SettingsSection(title: "Permissão") {
                SettingsRow(title: "Acessibilidade",
                            subtitle: "Necessária para contar as janelas abertas de cada app.") {
                    if permissions.isAccessibilityTrusted {
                        Label("Concedida", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(VibeColor.success)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Conceder…") { permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            }

            Label("**⌘W** conta como fechar — o macOS não distingue o atalho do clique no botão vermelho. O Hone só fecha uma app quando tem a certeza de que ficou sem janelas: minimizada, escondida, noutro Espaço ou em ecrã inteiro conta como aberta, e uma app que nunca viu com janela é deixada em paz. O **Finder** e o **Steam** nunca são fechados.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
    }

    // MARK: - Rows

    private func appRow(bundleID: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            if let icon = appIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(appName(for: bundleID))
                if appName(for: bundleID) != bundleID {
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                module.settings.remove(bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remover da lista")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func emptyMessage(for mode: QuitOnCloseMode) -> String {
        switch mode {
        case .allExcept:
            return "Sem exceções — todas as apps saem ao fechar a última janela."
        case .onlySelected:
            return "Nenhuma app escolhida — por agora não sai nenhuma."
        }
    }

    // MARK: - App lookup

    private func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = appURL(for: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The installed app's display name, falling back to the bundle id so a list
    /// entry for an app that isn't installed here still reads as something.
    private func appName(for bundleID: String) -> String {
        guard let url = appURL(for: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Adicionar"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            module.settings.add(bundleID) // ignores duplicates
        }
    }
}
