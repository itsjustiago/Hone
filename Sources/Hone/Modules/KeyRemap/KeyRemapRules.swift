import Foundation

/// One entry of the system's `UserKeyMapping`: the key that is pressed (`src`) and
/// the key the system sees instead (`dst`). Both are HID usages written the way
/// `hidutil` writes them: the usage page in the upper 32 bits, the usage below.
struct KeyRemapPair: Hashable {
    let src: UInt64
    let dst: UInt64

    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    init(src: UInt64, dst: UInt64) {
        self.src = src
        self.dst = dst
    }

    /// Reads one element of the array the system hands back; `nil` when it is not a pair of numbers.
    init?(_ entry: Any) {
        guard let entry = entry as? [String: Any],
              let src = (entry[Self.srcKey] as? NSNumber)?.int64Value,
              let dst = (entry[Self.dstKey] as? NSNumber)?.int64Value
        else { return nil }
        self.src = UInt64(bitPattern: src)
        self.dst = UInt64(bitPattern: dst)
    }

    /// The element as the system (and `UserDefaults`) stores it. Bit patterns, so a
    /// value somebody else wrote with the top bit set survives a round trip.
    var entry: [String: Any] {
        [Self.srcKey: NSNumber(value: Int64(bitPattern: src)),
         Self.dstKey: NSNumber(value: Int64(bitPattern: dst))]
    }
}

/// The pure half of Key Remap: which key ids exist, the HID usages behind them,
/// the pairs a choice turns into, and how those pairs share the system's mapping
/// with whatever else put entries there. Nothing here touches the HID system.
enum KeyRemapRules {
    /// What a key that was never remapped is called in the settings; never stored as a destination.
    static let normalID = "normal"

    // MARK: Keys

    /// A key that can be remapped. ⌃ ⌥ ⌘ have two (left and right), and both are remapped.
    struct Source {
        let id: String
        /// Row title in the settings.
        let title: String
        /// How the key is written in a sentence.
        let short: String
        let left: UInt64
        let right: UInt64?
    }

    /// A key a source can become.
    struct Target {
        let id: String
        /// In the menu.
        let title: String
        /// On the pill: short enough for a narrow row.
        let label: String
        /// The submenu it lives in; `nil` for the keys listed at the top.
        let group: String?
        /// 0 for the top-level keys, 1 for the submenus, 2 for "off": the menu draws a divider between them.
        let section: Int
        let left: UInt64
        /// The right-hand key when the target has sides, so a right-hand source lands on a right-hand key.
        let right: UInt64?
    }

    private static let keyboardPage: UInt64 = 0x7 << 32
    private static func key(_ usage: UInt64) -> UInt64 { keyboardPage | usage }

    /// The Fn / 🌐 key: usage 3 on Apple's vendor page (0xFF).
    static let fnUsage: UInt64 = 0xFF << 32 | 0x03
    /// Usage 0 of the keyboard page is "no event": the key stops doing anything.
    static let noneUsage: UInt64 = keyboardPage

    static let sources: [Source] = [
        Source(id: "fn", title: "🌐 Fn", short: "Fn", left: fnUsage, right: nil),
        Source(id: "control", title: "⌃ Control", short: "⌃", left: key(0xE0), right: key(0xE4)),
        Source(id: "option", title: "⌥ Option", short: "⌥", left: key(0xE2), right: key(0xE6)),
        Source(id: "command", title: "⌘ Command", short: "⌘", left: key(0xE3), right: key(0xE7)),
    ]

    /// Every destination, in the order the menu lists them.
    static let targets: [Target] = {
        func top(_ id: String, _ title: String, _ left: UInt64, _ right: UInt64? = nil) -> Target {
            Target(id: id, title: title, label: title, group: nil, section: 0, left: left, right: right)
        }
        func grouped(_ group: String, _ id: String, _ title: String, label: String? = nil, _ usage: UInt64) -> Target {
            Target(id: id, title: title, label: label ?? title, group: group, section: 1, left: key(usage), right: nil)
        }

        var list: [Target] = [
            top("control", "⌃ Control", key(0xE0), key(0xE4)),
            top("option", "⌥ Option", key(0xE2), key(0xE6)),
            top("command", "⌘ Command", key(0xE3), key(0xE7)),
            top("shift", "⇧ Shift", key(0xE1), key(0xE5)),
            top("capsLock", "⇪ Caps Lock", key(0x39)),
            top("fn", "🌐 Fn", fnUsage),
        ]

        let special = "Especiais"
        list += [
            grouped(special, "escape", "Escape", label: "Esc", 0x29),
            grouped(special, "return", "Return", 0x28),
            grouped(special, "delete", "Apagar", 0x2A),
            grouped(special, "forwardDelete", "Apagar à frente", 0x4C),
            grouped(special, "tab", "Tab", 0x2B),
            grouped(special, "space", "Espaço", 0x2C),
            grouped(special, "home", "Home", 0x4A),
            grouped(special, "end", "End", 0x4D),
            grouped(special, "pageUp", "Page Up", 0x4B),
            grouped(special, "pageDown", "Page Down", 0x4E),
        ]

        let arrows = "Setas"
        list += [
            grouped(arrows, "arrowUp", "↑ Seta para cima", label: "↑", 0x52),
            grouped(arrows, "arrowDown", "↓ Seta para baixo", label: "↓", 0x51),
            grouped(arrows, "arrowLeft", "← Seta para a esquerda", label: "←", 0x50),
            grouped(arrows, "arrowRight", "→ Seta para a direita", label: "→", 0x4F),
        ]

        // F1–F12 are usages 0x3A–0x45 and F13–F20 are 0x68–0x6F: two runs, not one.
        let functionKeys = "F1–F20"
        for number in 1...20 {
            let usage = UInt64(number <= 12 ? 0x39 + number : 0x68 + number - 13)
            list.append(grouped(functionKeys, "f\(number)", "F\(number)", usage))
        }

        // The 26 letters are usages 0x04–0x1D.
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".map(String.init).enumerated() {
            list.append(grouped("Letras", letter, letter.uppercased(), UInt64(0x04 + offset)))
        }

        // 1–9 are usages 0x1E–0x26 and 0 follows them at 0x27.
        for digit in [1, 2, 3, 4, 5, 6, 7, 8, 9, 0] {
            list.append(grouped("Números", "\(digit)", "\(digit)", UInt64(digit == 0 ? 0x27 : 0x1D + digit)))
        }

        list.append(Target(id: "none", title: "Desligada", label: "Desligada", group: nil, section: 2,
                           left: noneUsage, right: nil))
        return list
    }()

    private static let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    private static let targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })

    static func source(_ id: String) -> Source? { sourcesByID[id] }
    static func target(_ id: String) -> Target? { targetsByID[id] }

    // MARK: Choices to pairs

    /// What a stored choice map really says: only known keys, and nothing for a key set to
    /// itself or to "normal". Unknown ids are dropped rather than failing the rest.
    static func effective(_ map: [String: String]) -> [String: String] {
        map.filter { source, destination in
            sourcesByID[source] != nil && targetsByID[destination] != nil && source != destination
        }
    }

    /// The pairs that make `map` true, in the order of `sources`: a source with two sides
    /// gives two pairs, left to left and right to right (or both to the one key of a target without sides).
    static func pairs(from map: [String: String]) -> [KeyRemapPair] {
        let choices = effective(map)
        var result: [KeyRemapPair] = []
        for source in sources {
            guard let id = choices[source.id], let target = targetsByID[id] else { continue }
            result.append(KeyRemapPair(src: source.left, dst: target.left))
            if let right = source.right {
                result.append(KeyRemapPair(src: right, dst: target.right ?? target.left))
            }
        }
        return result
    }

    // MARK: Sharing the system's mapping

    /// The mapping to write: everything somebody else put there, then ours. An entry of
    /// somebody else's for a key we remap now is replaced, and the pairs we wrote last time
    /// (`previous`) are dropped so that changing a choice never leaves the old one behind.
    static func merged(existing: [KeyRemapPair], applying ours: [KeyRemapPair],
                       replacing previous: [KeyRemapPair]) -> [KeyRemapPair] {
        let ourKeys = Set(ours.map(\.src))
        let foreign = existing.filter { !previous.contains($0) && !ourKeys.contains($0.src) }
        return foreign + ours
    }

    /// The mapping without the pairs we wrote; entries of anybody else's stay as they were.
    static func removing(_ ours: [KeyRemapPair], from existing: [KeyRemapPair]) -> [KeyRemapPair] {
        existing.filter { !ours.contains($0) }
    }

    // MARK: Reading and writing

    /// Reads the array the system (or `UserDefaults`) holds; anything that is not a pair is skipped.
    static func decode(_ raw: Any?) -> [KeyRemapPair] {
        (raw as? [Any])?.compactMap { KeyRemapPair($0) } ?? []
    }

    static func encode(_ pairs: [KeyRemapPair]) -> [[String: Any]] {
        pairs.map(\.entry)
    }

    // MARK: Notes

    /// With Key Swap on, a key that now sends ⌃ or ⌘ ends up as the other one: Key Swap
    /// runs after the HID mapping. One sentence per key where that changes what it is
    /// ("Fn funciona como ⌘"); a key that lands back on itself says nothing.
    static func keySwapNotes(for map: [String: String]) -> [String] {
        let choices = effective(map)
        var notes: [String] = []
        for source in sources {
            guard let destination = choices[source.id], destination == "control" || destination == "command"
            else { continue }
            let landsOn = destination == "control" ? "command" : "control"
            guard landsOn != source.id else { continue }
            notes.append("\(source.short) funciona como \(landsOn == "control" ? "⌃" : "⌘")")
        }
        return notes
    }
}
