import Foundation
import XCTest
@testable import LidFoldKit

/// Everything the Kit puts in front of the user is PT-PT. The internal
/// `FailOpenReason` identifiers stay in English; only their messages are shown.
final class PortugueseTextsTests: XCTestCase {
    private typealias Reason = LidFoldPolicy.FailOpenReason

    private static let englishWords = try! NSRegularExpression(
        pattern: #"\b(the|not|is|are|was|failed|failure|unavailable|available|could|cannot|error|missing|invalid|stopped|display|screen)\b"#,
        options: .caseInsensitive)

    private func assertPortuguese(_ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let range = NSRange(text.startIndex..., in: text)
        let match = Self.englishWords.firstMatch(in: text, range: range)
        XCTAssertNil(match.map { (text as NSString).substring(with: $0.range) },
                     "\(what) has an English word: \(text)", file: file, line: line)
    }

    func testTheFailureMessagesAreTheExactPortugueseOnes() {
        XCTAssertEqual(Reason.captureFailed("x").failureMessage, "A captura do ecrã parou: x")
        XCTAssertEqual(Reason.captureUnavailable.failureMessage, "O ecrã deixou de enviar imagens.")
        XCTAssertEqual(Reason.noFrame.failureMessage, "O ecrã não chegou a tempo.")
        XCTAssertEqual(Reason.rendererFailed("x").failureMessage, "A renderização falhou: x")
        XCTAssertEqual(Reason.watchdog.failureMessage, "A sobreposição foi retirada por ficar tempo demais.")
    }

    func testRoutineReasonsShowNothingToTheUser() {
        let routine: [Reason] = [.stopped, .spaceChanged, .screenParametersChanged, .systemSleep, .screensAsleep,
                                 .sessionInactive, .displayUnavailable, .clockAnomaly]
        for reason in routine { XCTAssertNil(reason.failureMessage, "\(reason)") }
    }

    func testTheEffectNamesAndSummariesArePortuguese() {
        XCTAssertEqual(FoldEffect.allCases.map(\.title), ["Duo", "Fantasma", "Rolo", "Persiana", "Flexão", "Íris"])
        for effect in FoldEffect.allCases {
            assertPortuguese(effect.title, "title of \(effect)")
            assertPortuguese(effect.summary, "summary of \(effect)")
            XCTAssertTrue(effect.summary.hasSuffix("."), "\(effect)")
        }
    }

    func testTheOwnErrorsCarryTheirMessageUnchanged() {
        XCTAssertEqual(CaptureError("Falhou.").localizedDescription, "Falhou.")
        XCTAssertEqual(FoldRenderError("Falhou.").localizedDescription, "Falhou.")
    }

    /// The errors cannot all be provoked without a screen or a broken GPU, so the
    /// literals handed to them are checked where they are written.
    func testEveryUserVisibleLiteralInTheKitSourcesIsPortuguese() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LidFoldKit")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sources.path), "sources are not next to the tests")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(
            pattern: #"(?:CaptureError|FoldRenderError|rendererFailed)\(\s*"([^"\\]+)"|\?\? "([^"\\]+)""#)
        var literals: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                for group in 1...2 where match.range(at: group).location != NSNotFound {
                    literals.append((text as NSString).substring(with: match.range(at: group)))
                }
            }
        }
        XCTAssertGreaterThan(literals.count, 15, "the scan must actually find the messages")
        for literal in literals { assertPortuguese(literal, "message") }
    }
}
