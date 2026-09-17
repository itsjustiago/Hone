import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeySwapSettingsView: View {
    @Bindable var module: KeySwapModule
    @State private var permissions = Permissions.shared

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Exceções") {
                if settings.exceptions.isEmpty {
                    Text("Sem exceções — a troca vale em todas as apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    RowDivider()
                } else {
                    ForEach(settings.exceptions, id: \.self) { bundleID in
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
                            subtitle: "Necessária para reescrever os eventos de teclado.") {
                    if permissions.isAccessibilityTrusted {
                        Label("Concedida", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Conceder…") { permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            }

            Label("A troca vale para as teclas **esquerda e direita**, nos dois sentidos. O **Tab nunca é trocado**: ⌘Tab continua a ser o alternador de apps (o Alt-Tab) e ⌃Tab continua a mudar de separador, como no Windows. O rato não é tocado: **⌃+clique continua a ser o clique-direito** do macOS. Em campos de palavra-passe com *secure input* o macOS bloqueia qualquer app de ler o teclado, por isso a troca fica suspensa enquanto lá escreves.",
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
