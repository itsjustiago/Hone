import SwiftUI
import HoneDesign
import LidFoldKit

/// Animates the built-in display when the lid moves (the "iPhone Duo" fold). The
/// engine lives in `LidFoldKit`; this is the switch, the saved choices and the
/// pane. It never touches brightness, display sleep or power assertions: Sleepy
/// owns those, and the two share this process.
@MainActor
@Observable
final class LidFoldModule: HoneModule {
    let id = "lidFold"
    let title = "Dobra da tampa"
    let summary = "Anima o ecrã interno quando fechas ou abres a tampa — só mexe no ecrã, e só enquanto a tampa se mexe."
    let iconSystemName = "laptopcomputer"
    let tint = VibeToolColor.lidFold
    let category = "Ecrã"
    let shortTitle = "Tampa"
    let tagline = "O ecrã dobra-se quando fechas ou abres a tampa."
    let isAvailable = true
    let requiresAccessibility = false

    /// Length of the pane's "Testar" run, in seconds. Nonisolated: the status texts read it.
    nonisolated static let testSeconds = 8

    let settings: LidFoldSettings
    private let controller: LidFoldController

    /// The controller's status, copied here: `@Observable` can't see its callback.
    private(set) var status = LidFoldController.Status.stopped

    var isRunning: Bool { status != .stopped }

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        let settings = LidFoldSettings()
        let controller = LidFoldController()
        self.settings = settings
        self.controller = controller
        isEnabled = ModuleDefaults.isEnabled("lidFold", default: false)

        controller.onStatusChange = { [weak self] status in self?.status = status }
        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()
    }

    func start() {
        applySettings()
        controller.start()
    }

    func stop() { controller.stop() }

    /// Plays the animation without touching the lid. False when it could not begin;
    /// `status` then says why.
    @discardableResult
    func testNow() -> Bool {
        controller.playTest(duration: TimeInterval(Self.testSeconds))
    }

    func makeSettingsView() -> AnyView {
        AnyView(LidFoldSettingsView(module: self))
    }

    private func applySettings() {
        controller.effect = settings.effect
        controller.captureEnabled = settings.captureEnabled
    }
}
