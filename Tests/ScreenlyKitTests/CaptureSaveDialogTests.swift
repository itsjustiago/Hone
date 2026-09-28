import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import ScreenlyKit

/// Covers what the "Guardar" dialog is seeded with: the folder it opens in and
/// the file type it enforces. The dialog itself is never shown.
@MainActor
final class CaptureSaveDialogTests: XCTestCase {
    private static let suite = "com.tiagof.screenly.tests.savedialog"
    private var realStore: UserDefaults!
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        realStore = ScreenlyDefaults.store
        UserDefaults().removePersistentDomain(forName: Self.suite)
        ScreenlyDefaults.store = UserDefaults(suiteName: Self.suite)!
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenly-save-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        UserDefaults().removePersistentDomain(forName: Self.suite)
        ScreenlyDefaults.store = realStore
        super.tearDown()
    }

    func testContentTypeFollowsFormat() {
        XCTAssertEqual(CaptureSaveDialog.contentType(for: "png"), .png)
        XCTAssertEqual(CaptureSaveDialog.contentType(for: "jpg"), .jpeg)
    }

    func testFallsBackToSaveFolderAndCreatesIt() {
        let folder = tmp.appendingPathComponent("Screenly", isDirectory: true)
        CaptureSettings.saveFolder = folder
        XCTAssertEqual(CaptureSaveDialog.initialDirectory().path, folder.path)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testWriteRemembersFolder() throws {
        CaptureSettings.saveFolder = tmp.appendingPathComponent("Default", isDirectory: true)
        let chosen = tmp.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let url = chosen.appendingPathComponent("x.png")

        XCTAssertNil(CaptureSaveDialog.write(Data([1, 2, 3]), to: url))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(CaptureSaveDialog.initialDirectory().path, chosen.path)
    }

    func testFailedWriteKeepsPreviousFolder() {
        let fallback = tmp.appendingPathComponent("Default", isDirectory: true)
        CaptureSettings.saveFolder = fallback
        let bad = tmp.appendingPathComponent("missing/deeper/x.png")
        XCTAssertNotNil(CaptureSaveDialog.write(Data([1]), to: bad))
        XCTAssertEqual(CaptureSaveDialog.initialDirectory().path, fallback.path)
    }

    func testVanishedLastFolderFallsBack() {
        let fallback = tmp.appendingPathComponent("Default", isDirectory: true)
        CaptureSettings.saveFolder = fallback
        ScreenlyDefaults.store.set(tmp.appendingPathComponent("gone").path,
                                   forKey: CaptureSaveDialog.lastDirectoryKey)
        XCTAssertEqual(CaptureSaveDialog.initialDirectory().path, fallback.path)
    }

    func testPanelIsSeeded() {
        CaptureSettings.saveFolder = tmp
        let panel = CaptureSaveDialog.makePanel(ext: "jpg")
        XCTAssertTrue(panel.nameFieldStringValue.hasPrefix("Captura "))
        XCTAssertTrue(panel.nameFieldStringValue.hasSuffix(".jpg"))
        XCTAssertEqual(panel.allowedContentTypes, [.jpeg])
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertEqual(panel.prompt, "Guardar")
    }
}
