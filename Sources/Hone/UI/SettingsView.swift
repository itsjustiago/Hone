import SwiftUI

struct SettingsView: View {
    @Bindable var manager: ModuleManager
    var updateChecker: UpdateChecker
    @State private var selection: String = "scroll"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Ferramentas") {
                    ForEach(manager.modules, id: \.id) { module in
                        SidebarRow(icon: module.iconSystemName, tint: module.tint, title: module.title)
                            .tag(module.id)
                    }
                }
                Section {
                    SidebarRow(icon: "gearshape.fill", tint: .gray, title: "Geral")
                        .tag("general")
                }
            }
            .navigationSplitViewColumnWidth(212)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 9) {
            ModuleIcon(systemName: "slider.horizontal.3", tint: .accentColor, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Hone").font(.system(size: 14, weight: .bold))
                Text("Ferramentas para o Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var detail: some View {
        if selection == "general" {
            GeneralSettingsView(updateChecker: updateChecker)
        } else if let module = manager.modules.first(where: { $0.id == selection }) {
            ModuleDetailView(module: module, manager: manager)
        } else {
            ContentUnavailableView("Escolhe uma ferramenta", systemImage: "sidebar.left")
        }
    }
}

private struct SidebarRow: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            ModuleIcon(systemName: icon, tint: tint, size: 20)
            Text(title)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Module detail

private struct ModuleDetailView: View {
    let module: any HoneModule
    @Bindable var manager: ModuleManager
    @State private var permissions = Permissions.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if module.isAvailable, manager.isWaitingOnPermission(module) {
                    PermissionBanner(tint: module.tint) { permissions.openAccessibilitySettings() }
                }

                let dimmed = module.isAvailable && !module.isMomentary && !module.isEnabled
                module.makeSettingsView()
                    .disabled(dimmed)
                    .opacity(dimmed ? 0.45 : 1)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 15) {
            ModuleIcon(systemName: module.iconSystemName, tint: module.tint, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title).font(.title2.weight(.bold))
                Text(module.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if module.isMomentary {
                Button(module.actionLabel, action: module.performAction)
                    .buttonStyle(.borderedProminent)
                    .tint(module.tint)
                    .controlSize(.large)
            } else {
                Toggle("", isOn: Binding(
                    get: { module.isEnabled },
                    set: { manager.setEnabled($0, for: module) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(module.tint)
                .controlSize(.large)
            }
        }
    }
}

private struct PermissionBanner: View {
    let tint: Color
    let action: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Falta acesso de Acessibilidade").font(.callout.weight(.medium))
                Text("O Hone precisa dele para esta ferramenta funcionar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Abrir Definições…", action: action)
                .controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.orange.opacity(0.25))
        )
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    var updateChecker: UpdateChecker
    @State private var launch = LaunchAtLogin.shared
    @State private var autoCheck = Updater.autoCheckEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 15) {
                    ModuleIcon(systemName: "gearshape.fill", tint: .gray, size: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Geral").font(.title2.weight(.bold))
                        Text("Preferências gerais do Hone.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                SettingsSection(title: "Arranque") {
                    ToggleRow(title: "Abrir o Hone no arranque",
                              subtitle: "Inicia automaticamente quando entras na sessão.",
                              tint: .accentColor,
                              isOn: Binding(get: { launch.isEnabled },
                                            set: { launch.isEnabled = $0 }))
                }

                SettingsSection(title: "Atualizações") {
                    ToggleRow(title: "Procurar automaticamente",
                              tint: .accentColor,
                              isOn: Binding(get: { autoCheck },
                                            set: { autoCheck = $0; Updater.autoCheckEnabled = $0 }))
                    RowDivider()
                    SettingsRow(title: "Versão \(Updater.currentVersion)",
                                subtitle: updateChecker.status.isEmpty ? nil : updateChecker.status) {
                        if let update = updateChecker.availableUpdate {
                            Button("Atualizar para \(update.version)") { updateChecker.install() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        } else {
                            Button("Procurar agora") { updateChecker.checkNow() }
                                .controlSize(.small)
                        }
                    }
                }

                SettingsSection(title: "Sobre") {
                    SettingsRow(title: "Hone",
                                subtitle: "Uma caixa de ferramentas modular para o macOS. Mais ferramentas a caminho.") {
                        EmptyView()
                    }
                    RowDivider()
                    HStack {
                        Spacer()
                        Button("Sair do Hone", role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        }
                        .controlSize(.regular)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }
}
