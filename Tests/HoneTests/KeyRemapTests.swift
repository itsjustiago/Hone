import XCTest
import AppKit
@testable import Hone
@testable import HoneDesign

// None of these touch the HID system or `UserDefaults.standard`: the rules are pure and the
// settings read a throwaway suite.

private func pair(_ src: UInt64, _ dst: UInt64) -> KeyRemapPair { KeyRemapPair(src: src, dst: dst) }

private let fn: UInt64 = 0xFF_0000_0003
private let leftControl: UInt64 = 0x7_0000_00E0
private let rightControl: UInt64 = 0x7_0000_00E4
private let leftOption: UInt64 = 0x7_0000_00E2
private let rightOption: UInt64 = 0x7_0000_00E6
private let leftCommand: UInt64 = 0x7_0000_00E3
private let rightCommand: UInt64 = 0x7_0000_00E7

// MARK: - Choices to pairs

final class KeyRemapPairsTests: XCTestCase {
    func testFnAsControlIsOnePairToTheLeftControl() {
        XCTAssertEqual(KeyRemapRules.pairs(from: ["fn": "control"]), [pair(fn, leftControl)])
    }

    func testCommandAsControlRemapsBothSidesSideToSide() {
        XCTAssertEqual(KeyRemapRules.pairs(from: ["command": "control"]),
                       [pair(leftCommand, leftControl), pair(rightCommand, rightControl)])
    }

    func testControlAndCommandTradingPlacesIsFourPairs() {
        let pairs = KeyRemapRules.pairs(from: ["control": "command", "command": "control"])
        XCTAssertEqual(pairs, [
            pair(leftControl, leftCommand), pair(rightControl, rightCommand),
            pair(leftCommand, leftControl), pair(rightCommand, rightControl),
        ])
    }

    func testAKeyWithNoSidesTakesBothSidesOfTheSource() {
        // Escape is 0x29; Caps Lock 0x39.
        XCTAssertEqual(KeyRemapRules.pairs(from: ["option": "escape"]),
                       [pair(leftOption, 0x7_0000_0029), pair(rightOption, 0x7_0000_0029)])
        XCTAssertEqual(KeyRemapRules.pairs(from: ["control": "capsLock"]),
                       [pair(leftControl, 0x7_0000_0039), pair(rightControl, 0x7_0000_0039)])
    }

    func testFnAsAModifierWithSidesIsTheLeftOne() {
        XCTAssertEqual(KeyRemapRules.pairs(from: ["fn": "option"]), [pair(fn, leftOption)])
        XCTAssertEqual(KeyRemapRules.pairs(from: ["fn": "shift"]), [pair(fn, 0x7_0000_00E1)])
    }

    func testAnythingBecomingFnLandsOnTheFnUsage() {
        XCTAssertEqual(KeyRemapRules.pairs(from: ["control": "fn"]),
                       [pair(leftControl, fn), pair(rightControl, fn)])
    }

    func testOffIsTheReservedUsage() {
        XCTAssertEqual(KeyRemapRules.pairs(from: ["fn": "none"]), [pair(fn, 0x7_0000_0000)])
    }

    func testPairsComeInTheOrderOfTheSources() {
        let pairs = KeyRemapRules.pairs(from: ["command": "option", "fn": "control", "option": "command"])
        XCTAssertEqual(pairs.map(\.src), [fn, leftOption, rightOption, leftCommand, rightCommand])
    }

    func testAKeyLeftAloneOrSetToItselfMakesNoPair() {
        XCTAssertEqual(KeyRemapRules.pairs(from: [:]), [])
        XCTAssertEqual(KeyRemapRules.pairs(from: ["control": "control", "fn": "fn"]), [])
        XCTAssertEqual(KeyRemapRules.pairs(from: ["option": KeyRemapRules.normalID]), [])
    }

    func testUnknownIdsAreIgnoredAndTheRestStillApplies() {
        let map = ["fn": "control", "capsLock": "escape", "option": "nothing", "command": ""]
        XCTAssertEqual(KeyRemapRules.pairs(from: map), [pair(fn, leftControl)])
        XCTAssertEqual(KeyRemapRules.effective(map), ["fn": "control"])
    }
}

// MARK: - The catalogue

final class KeyRemapCatalogueTests: XCTestCase {
    private func usage(_ id: String) throws -> UInt64 {
        try XCTUnwrap(KeyRemapRules.target(id)).left
    }

    func testIdsAreUniqueAndEveryKeyHasItsOwnUsage() {
        let ids = KeyRemapRules.targets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let usages = KeyRemapRules.targets.map(\.left)
        XCTAssertEqual(Set(usages).count, usages.count, "two keys sharing a usage would be one key")
    }

    func testTheUsagesAreTheOnesTheHIDTableSays() throws {
        for (id, expected) in [("escape", 0x29), ("return", 0x28), ("delete", 0x2A), ("tab", 0x2B), ("space", 0x2C),
                               ("forwardDelete", 0x4C), ("home", 0x4A), ("end", 0x4D), ("pageUp", 0x4B),
                               ("pageDown", 0x4E), ("arrowRight", 0x4F), ("arrowLeft", 0x50),
                               ("arrowDown", 0x51), ("arrowUp", 0x52),
                               ("f1", 0x3A), ("f5", 0x3E), ("f12", 0x45), ("f13", 0x68), ("f20", 0x6F),
                               ("a", 0x04), ("z", 0x1D), ("1", 0x1E), ("9", 0x26), ("0", 0x27)] {
            XCTAssertEqual(try usage(id), 0x7_0000_0000 | UInt64(expected), id)
        }
    }

    func testTheModifiersHaveBothSides() throws {
        let control = try XCTUnwrap(KeyRemapRules.target("control"))
        XCTAssertEqual([control.left, control.right], [leftControl, rightControl])
        let shift = try XCTUnwrap(KeyRemapRules.target("shift"))
        XCTAssertEqual([shift.left, shift.right], [0x7_0000_00E1, 0x7_0000_00E5])
        XCTAssertNil(KeyRemapRules.target("capsLock")?.right)
        XCTAssertEqual(try usage("fn"), fn)
        XCTAssertEqual(try usage("none"), 0x7_0000_0000)
    }

    func testTheFourSourcesAreFnControlOptionCommand() {
        XCTAssertEqual(KeyRemapRules.sources.map(\.id), ["fn", "control", "option", "command"])
    }

    func testTheKeySwapNoteNamesWhatTheKeyBecomes() {
        XCTAssertEqual(KeyRemapRules.keySwapNotes(for: ["fn": "control"]), ["Fn funciona como ⌘"])
        XCTAssertEqual(KeyRemapRules.keySwapNotes(for: ["fn": "command", "option": "control"]),
                       ["Fn funciona como ⌃", "⌥ funciona como ⌘"])
    }

    func testTheKeySwapNoteIsSilentWhenItChangesNothing() {
        XCTAssertEqual(KeyRemapRules.keySwapNotes(for: [:]), [])
        XCTAssertEqual(KeyRemapRules.keySwapNotes(for: ["fn": "escape", "option": "shift"]), [])
        // ⌘ becomes ⌃ and Key Swap turns it back into ⌘; the same the other way round.
        XCTAssertEqual(KeyRemapRules.keySwapNotes(for: ["command": "control", "control": "command"]), [])
    }
}

// MARK: - Sharing the system's mapping

final class KeyRemapMergeTests: XCTestCase {
    private let ours = [pair(fn, leftControl)]
    /// F19 to F20: nothing anyone presses, standing in for another tool's entry.
    private let foreign = pair(0x7_0000_006E, 0x7_0000_006F)

    func testOurPairsAreAddedAfterWhatWasThere() {
        XCTAssertEqual(KeyRemapRules.merged(existing: [foreign], applying: ours, replacing: []), [foreign] + ours)
        XCTAssertEqual(KeyRemapRules.merged(existing: [], applying: ours, replacing: []), ours)
    }

    func testAnEntryOfSomebodyElsesForTheSameKeyIsReplaced() {
        let theirs = pair(fn, 0x7_0000_0029)
        XCTAssertEqual(KeyRemapRules.merged(existing: [theirs, foreign], applying: ours, replacing: []), [foreign] + ours)
    }

    func testAnEntryForAnotherKeyStays() {
        let capsToEscape = pair(0x7_0000_0039, 0x7_0000_0029)
        XCTAssertEqual(KeyRemapRules.merged(existing: [capsToEscape], applying: ours, replacing: []), [capsToEscape] + ours)
    }

    func testWhatWeWroteLastTimeGoesWhenTheChoiceChanges() {
        let before = [pair(fn, leftControl)]
        let now = [pair(leftOption, leftCommand), pair(rightOption, rightCommand)]
        let merged = KeyRemapRules.merged(existing: [foreign] + before, applying: now, replacing: before)
        XCTAssertEqual(merged, [foreign] + now)
    }

    func testChoosingNothingAnymoreLeavesOnlyTheOthers() {
        XCTAssertEqual(KeyRemapRules.merged(existing: [foreign] + ours, applying: [], replacing: ours), [foreign])
    }

    func testWritingTwiceGivesTheSameMapping() {
        let once = KeyRemapRules.merged(existing: [foreign], applying: ours, replacing: [])
        let twice = KeyRemapRules.merged(existing: once, applying: ours, replacing: ours)
        XCTAssertEqual(twice, once)
    }

    func testRemovingTakesOnlyOurPairs() {
        XCTAssertEqual(KeyRemapRules.removing(ours, from: [foreign] + ours), [foreign])
        XCTAssertEqual(KeyRemapRules.removing(ours, from: ours), [])
        XCTAssertEqual(KeyRemapRules.removing(ours, from: [foreign]), [foreign])
    }

    func testAnEntryWithOurKeyButAnotherTargetIsNotOurs() {
        // Somebody changed what Fn does after we wrote it: that entry is theirs now.
        let changed = pair(fn, 0x7_0000_0029)
        XCTAssertEqual(KeyRemapRules.removing(ours, from: [changed]), [changed])
    }

    func testRemovingWithNothingAppliedChangesNothing() {
        XCTAssertEqual(KeyRemapRules.removing([], from: [foreign]), [foreign])
    }
}

// MARK: - Reading and writing

final class KeyRemapCodingTests: XCTestCase {
    func testTheSystemsShapeRoundTrips() {
        let pairs = [pair(fn, leftControl), pair(leftCommand, leftControl)]
        XCTAssertEqual(KeyRemapRules.decode(KeyRemapRules.encode(pairs)), pairs)
    }

    func testTheKeysAreTheOnesHidutilUses() throws {
        let entry = pair(fn, leftControl).entry
        XCTAssertEqual((entry["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.int64Value, 0xFF_0000_0003)
        XCTAssertEqual((entry["HIDKeyboardModifierMappingDst"] as? NSNumber)?.int64Value, 0x7_0000_00E0)
    }

    func testAnythingThatIsNotAPairIsSkipped() {
        let raw: [Any] = [
            ["HIDKeyboardModifierMappingSrc": 1, "HIDKeyboardModifierMappingDst": 2],
            ["HIDKeyboardModifierMappingSrc": 1],
            "text",
            ["other": 5],
        ]
        XCTAssertEqual(KeyRemapRules.decode(raw), [pair(1, 2)])
        XCTAssertEqual(KeyRemapRules.decode(nil), [])
        XCTAssertEqual(KeyRemapRules.decode("nope"), [])
    }

    func testAValueWithTheTopBitSetSurvives() {
        let odd = pair(0xFFFF_FFFF_0000_0000, 0x7_0000_0000)
        XCTAssertEqual(KeyRemapRules.decode(KeyRemapRules.encode([odd])), [odd])
    }
}

// MARK: - The choices

@MainActor
final class KeyRemapSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "com.tiagof.hone.tests.keyremap.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNothingIsRemappedByDefault() {
        let settings = KeyRemapSettings(defaults: defaults)
        XCTAssertEqual(settings.map, [:])
        XCTAssertFalse(settings.hasChanges)
        XCTAssertEqual(settings.destination(of: "fn"), KeyRemapRules.normalID)
    }

    func testAChoiceIsSavedAndReadBack() {
        let settings = KeyRemapSettings(defaults: defaults)
        settings.setDestination("control", of: "fn")
        XCTAssertEqual(defaults.dictionary(forKey: "keyRemap.map") as? [String: String], ["fn": "control"])
        XCTAssertTrue(settings.hasChanges)
        XCTAssertEqual(KeyRemapSettings(defaults: defaults).destination(of: "fn"), "control")
    }

    func testNormalOrTheKeyItselfClearsTheChoice() {
        let settings = KeyRemapSettings(defaults: defaults)
        settings.map = ["fn": "control", "option": "command"]
        settings.setDestination(KeyRemapRules.normalID, of: "fn")
        settings.setDestination("option", of: "option")
        XCTAssertEqual(settings.map, [:])
        XCTAssertFalse(settings.hasChanges)
    }

    func testIdsWrittenByHandThatMeanNothingAreIgnored() {
        defaults.set(["fn": "control", "capsLock": "escape", "option": "banana", "command": 3], forKey: "keyRemap.map")
        let settings = KeyRemapSettings(defaults: defaults)
        XCTAssertEqual(KeyRemapRules.pairs(from: settings.map), [pair(fn, leftControl)])
        XCTAssertEqual(settings.destination(of: "option"), KeyRemapRules.normalID)
        XCTAssertEqual(settings.destination(of: "command"), KeyRemapRules.normalID)
    }

    func testOnlyUnknownIdsMeansNoChanges() {
        defaults.set(["banana": "control"], forKey: "keyRemap.map")
        XCTAssertFalse(KeyRemapSettings(defaults: defaults).hasChanges)
    }

    func testResetPutsEveryKeyBack() {
        let settings = KeyRemapSettings(defaults: defaults)
        settings.map = ["fn": "control", "command": "option"]
        settings.reset()
        XCTAssertEqual(settings.map, [:])
        XCTAssertEqual(defaults.dictionary(forKey: "keyRemap.map") as? [String: String], [:])
    }

    func testEveryRealChangeIsToldAndASetToTheSameValueIsNot() {
        let settings = KeyRemapSettings(defaults: defaults)
        var told = 0
        settings.onChange = { told += 1 }
        settings.setDestination("control", of: "fn")
        settings.setDestination("control", of: "fn")
        XCTAssertEqual(told, 1)
        settings.setDestination("escape", of: "fn")
        settings.reset()
        settings.reset()
        XCTAssertEqual(told, 3)
    }
}

// MARK: - The menu

@MainActor
final class KeyRemapMenuTests: XCTestCase {
    private func menu(for sourceID: String, selection: String = KeyRemapRules.normalID) throws -> (NSMenu, [VibeMenuPicker<String>.Option]) {
        let source = try XCTUnwrap(KeyRemapRules.source(sourceID))
        let options = KeyRemapSettingsView.options(for: source)
        let menu = VibeMenuPicker<String>.makeMenu(title: source.title, options: options,
                                                   selection: selection, target: NSObject())
        return (menu, options)
    }

    func testNormalComesFirstThenTheModifiersThenTheSubmenusThenOff() throws {
        let (menu, _) = try menu(for: "fn")
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        XCTAssertEqual(titles, [
            "Normal", "-", "⌃ Control", "⌥ Option", "⌘ Command", "⇧ Shift", "⇪ Caps Lock",
            "-", "Especiais", "Setas", "F1–F20", "Letras", "Números", "-", "Desligada",
        ])
    }

    func testAKeyIsNotOfferedAsItself() throws {
        let (control, _) = try menu(for: "control")
        XCTAssertFalse(control.items.contains { $0.title == "⌃ Control" })
        XCTAssertTrue(control.items.contains { $0.title == "🌐 Fn" })
        let (fn, _) = try menu(for: "fn")
        XCTAssertFalse(fn.items.contains { $0.title == "🌐 Fn" })
    }

    func testTheSubmenusHoldTheirKeys() throws {
        let (menu, _) = try menu(for: "fn")
        func count(_ title: String) -> Int? { menu.items.first { $0.title == title }?.submenu?.items.count }
        XCTAssertEqual(count("Especiais"), 10)
        XCTAssertEqual(count("Setas"), 4)
        XCTAssertEqual(count("F1–F20"), 20)
        XCTAssertEqual(count("Letras"), 26)
        XCTAssertEqual(count("Números"), 10)
    }

    func testEveryOptionIsReachableByItsTag() throws {
        let (menu, options) = try menu(for: "option")
        var tags: [Int] = []
        func collect(_ menu: NSMenu) {
            for item in menu.items where !item.isSeparatorItem {
                if let submenu = item.submenu { collect(submenu) } else { tags.append(item.tag) }
            }
        }
        collect(menu)
        XCTAssertEqual(tags.sorted(), Array(options.indices))
    }

    func testTheChosenKeyIsTickedAndSoIsItsSubmenu() throws {
        let (menu, options) = try menu(for: "fn", selection: "f5")
        let functionKeys = try XCTUnwrap(menu.items.first { $0.title == "F1–F20" })
        XCTAssertEqual(functionKeys.state, .on)
        let ticked = try XCTUnwrap(functionKeys.submenu?.items.first { $0.state == .on })
        XCTAssertEqual(options[ticked.tag].value, "f5")
        XCTAssertEqual(menu.items.first { $0.title == "Letras" }?.state, .off)
        XCTAssertEqual(menu.items.first { $0.title == "Normal" }?.state, .off)
    }

    func testNormalIsTickedWhenNothingIsRemapped() throws {
        let (menu, _) = try menu(for: "command")
        XCTAssertEqual(menu.items.first?.title, "Normal")
        XCTAssertEqual(menu.items.first?.state, .on)
    }
}

// MARK: - The module

@MainActor
final class KeyRemapModuleTests: XCTestCase {
    /// Only builds the module (the engine stays stopped, so the HID system is not touched
    /// unless a previous run left `keyRemap.applied` behind, which a test process never has),
    /// and checks the preview fixture still mirrors its metadata.
    func testTheModuleIsOffByDefaultAndTheFixtureMirrorsIt() throws {
        let module = KeyRemapModule()
        XCTAssertEqual(module.id, "keyRemap")
        XCTAssertFalse(module.isEnabled)
        XCTAssertTrue(module.isAvailable)
        XCTAssertFalse(module.requiresAccessibility, "the HID mapping needs no permission")
        XCTAssertFalse(module.isMomentary)

        let spec = try XCTUnwrap(Fixture.all.first { $0.id == module.id })
        XCTAssertEqual(spec.title, module.title)
        XCTAssertEqual(spec.shortTitle, module.shortTitle)
        XCTAssertEqual(spec.category, module.category)
        XCTAssertEqual(spec.tagline, module.tagline)
        XCTAssertEqual(spec.icon, module.iconSystemName)
        XCTAssertFalse(spec.panel, "only the apps have a slime")
    }
}
