import AppKit
import SwiftUI
import HoneDesign
import UniformTypeIdentifiers

/// The body of an "apps this doesn't apply to" card: one row per bundle id (icon,
/// name and id, remove button), a line of text when the list is empty, and the
/// "Adicionar app…" button. Meant to sit inside a `SettingsSection`.
struct AppExceptionList: View {
    let bundleIDs: [String]
    let emptyText: String
    let tint: Color
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if bundleIDs.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                RowDivider()
            } else {
                ForEach(bundleIDs, id: \.self) { bundleID in
                    appRow(bundleID: bundleID)
                    RowDivider()
                }
            }

            HStack {
                Button("Adicionar app…") { addApps() }
                    .controlSize(.small)
                    .tint(tint.vibeControlTint)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Rows

    private func appRow(bundleID: String) -> some View {
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
                onRemove(bundleID)
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
            onAdd(bundleID) // the caller ignores duplicates
        }
    }
}
