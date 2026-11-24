import SwiftUI
import HoneDesign

struct KeyRemapSettingsView: View {
    let settings: KeyRemapSettings
    /// Key Swap runs after this tool, so whether it is on changes what a remapped key ends up as.
    @AppStorage private var keySwapOn: Bool
    @Environment(\.settingsPageScrolls) private var scrolls

    /// `keySwapDefaults` is only for the preview renders, which must not read the real ones.
    init(settings: KeyRemapSettings, keySwapDefaults: UserDefaults = .standard) {
        self.settings = settings
        _keySwapOn = AppStorage(wrappedValue: false, "keySwap.enabled", store: keySwapDefaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Teclas") {
                ForEach(Array(KeyRemapRules.sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { RowDivider() }
                    SettingsRow(title: source.title) {
                        VibeMenuPicker(source.title, selection: choice(of: source),
                                       options: Self.options(for: source), offscreen: !scrolls)
                    }
                }
            }

            if settings.hasChanges {
                HStack {
                    Spacer(minLength: 0)
                    Button("Repor tudo") { settings.reset() }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Vale em **todos os teclados**, também nos campos de palavra-passe, e não precisa de nenhuma permissão: a troca é feita pelo sistema, antes de qualquer app ver a tecla. ⌃, ⌥ e ⌘ trocam **os dois lados**. Uma tecla **desligada** deixa de fazer o que quer que seja.",
                      systemImage: "info.circle")
                if keySwapOn, let note = keySwapNote {
                    Label(note, systemImage: "arrow.left.arrow.right")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 6)
        }
    }

    // MARK: Pieces

    /// "Com o ⌘ ⇄ ⌃ ligado…", only when a key now sends ⌃ or ⌘ and Key Swap will turn it into the other.
    private var keySwapNote: String? {
        let notes = KeyRemapRules.keySwapNotes(for: settings.map)
        guard !notes.isEmpty else { return nil }
        return "Com o ⌘ ⇄ ⌃ ligado, a tecla acaba a funcionar como a outra: \(notes.joined(separator: "; "))."
    }

    private func choice(of source: KeyRemapRules.Source) -> Binding<String> {
        Binding(get: { settings.destination(of: source.id) },
                set: { settings.setDestination($0, of: source.id) })
    }

    /// "Normal", the modifiers, the submenus and "Desligada", leaving out the key itself.
    static func options(for source: KeyRemapRules.Source) -> [VibeMenuPicker<String>.Option] {
        var options = [VibeMenuPicker<String>.Option(KeyRemapRules.normalID, title: "Normal", label: "Normal")]
        var section = -1
        for target in KeyRemapRules.targets where target.id != source.id {
            options.append(.init(target.id, title: target.title, label: target.label,
                                 group: target.group, dividerBefore: target.section != section))
            section = target.section
        }
        return options
    }
}
