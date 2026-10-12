import XCTest
import LidFoldKit
@testable import Hone

/// The Lid Fold tool's saved choices and texts. Nothing here starts the controller:
/// that would light the overlay on the real display.
@MainActor
final class LidFoldSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HoneTests.lidFold.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Defaults and persistence

    func testDefaultsAreGhostAndCaptureOn() {
        let settings = LidFoldSettings(defaults: defaults)
        XCTAssertEqual(settings.effect, LidFoldSettings.defaultEffect)
        XCTAssertEqual(settings.effect, .ghost)
        XCTAssertTrue(settings.captureEnabled)
        XCTAssertTrue(LidFoldSettings.defaultCaptureEnabled)
    }

    func testChoicesSurviveARelaunch() {
        let first = LidFoldSettings(defaults: defaults)
        first.effect = .iris
        first.captureEnabled = false

        let second = LidFoldSettings(defaults: defaults)
        XCTAssertEqual(second.effect, .iris)
        XCTAssertFalse(second.captureEnabled)
    }

    func testEveryEffectRoundTrips() {
        for effect in FoldEffect.allCases {
            let settings = LidFoldSettings(defaults: defaults)
            settings.effect = effect
            XCTAssertEqual(LidFoldSettings(defaults: defaults).effect, effect, "\(effect)")
        }
    }

    /// Saved selections depend on the raw value, so the key holds exactly that.
    func testTheEffectIsStoredAsItsRawValue() {
        let settings = LidFoldSettings(defaults: defaults)
        settings.effect = .shutter
        XCTAssertEqual(defaults.string(forKey: "lidFold.effect"), "shutter")
        settings.captureEnabled = false
        XCTAssertEqual(defaults.object(forKey: "lidFold.captureEnabled") as? Bool, false)
    }

    func testAnUnknownSavedEffectFallsBackToTheDefault() {
        for junk in ["", "Duo", "wobble", " duo", "3"] {
            defaults.set(junk, forKey: "lidFold.effect")
            XCTAssertEqual(LidFoldSettings(defaults: defaults).effect, .ghost, "saved \"\(junk)\"")
        }
        defaults.set(42, forKey: "lidFold.effect")
        XCTAssertEqual(LidFoldSettings(defaults: defaults).effect, .ghost)
    }

    func testAnUnreadableCaptureFlagFallsBackToTheDefault() {
        defaults.set("talvez", forKey: "lidFold.captureEnabled")
        XCTAssertTrue(LidFoldSettings(defaults: defaults).captureEnabled)
        defaults.set(false, forKey: "lidFold.captureEnabled")
        XCTAssertFalse(LidFoldSettings(defaults: defaults).captureEnabled)
    }

    // MARK: Pushing changes to the controller

    func testOnChangeFiresOnlyForRealChanges() {
        let settings = LidFoldSettings(defaults: defaults)
        var calls = 0
        settings.onChange = { calls += 1 }

        settings.effect = .ghost // already the default
        settings.captureEnabled = true // already on
        XCTAssertEqual(calls, 0)

        settings.effect = .flex
        XCTAssertEqual(calls, 1)
        settings.captureEnabled = false
        XCTAssertEqual(calls, 2)
    }

    func testBuildingTheSettingsDoesNotWriteDefaults() {
        _ = LidFoldSettings(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "lidFold.effect"))
        XCTAssertNil(defaults.object(forKey: "lidFold.captureEnabled"))
    }

    // MARK: Texts

    func testTheSixEffectsHavePortugueseNames() {
        let expected: [FoldEffect: String] = [
            .duo: "Duo", .ghost: "Fantasma", .roll: "Rolo",
            .shutter: "Persiana", .flex: "Flexão", .iris: "Íris",
        ]
        XCTAssertEqual(FoldEffect.allCases.count, 6)
        XCTAssertEqual(Set(expected.keys), Set(FoldEffect.allCases), "one name per effect, no extras")
        for effect in FoldEffect.allCases {
            XCTAssertEqual(effect.displayName, expected[effect], "\(effect)")
        }
        XCTAssertEqual(Set(FoldEffect.allCases.map(\.displayName)).count, 6, "names must be distinct")
    }

    func testEveryStatusSaysSomethingInPortuguese() {
        XCTAssertEqual(LidFoldController.Status.stopped.message, "Desligado")
        XCTAssertEqual(LidFoldController.Status.running.message, "Pronto — fecha a tampa devagar")
        XCTAssertEqual(LidFoldController.Status.testing.message, "A testar…")
        XCTAssertEqual(LidFoldController.Status.noMetal.message, "Sem GPU Metal compatível")
        XCTAssertEqual(LidFoldController.Status.waitingForDisplay.message, "À espera do ecrã interno")
        XCTAssertEqual(LidFoldController.Status.failed("Sem imagem do ecrã.").message, "Sem imagem do ecrã.")
        let unsupported = LidFoldController.Status.unsupported.message
        XCTAssertTrue(unsupported.contains("sensor do ângulo da tampa"))
        XCTAssertTrue(unsupported.contains("O teste de \(LidFoldModule.testSeconds) s funciona na mesma."))
    }

    // MARK: The module

    /// Only builds the module (the controller stays stopped), and checks the
    /// preview fixture still mirrors its metadata.
    func testTheModuleIsOffByDefaultAndTheFixtureMirrorsIt() throws {
        let module = LidFoldModule()
        XCTAssertEqual(module.id, "lidFold")
        XCTAssertFalse(module.isEnabled)
        XCTAssertEqual(module.status, .stopped)
        XCTAssertFalse(module.isRunning)
        XCTAssertTrue(module.isAvailable)
        XCTAssertFalse(module.requiresAccessibility)
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
