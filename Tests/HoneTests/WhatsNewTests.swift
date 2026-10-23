import AppKit
import XCTest
@testable import Hone

/// A lógica do ecrã «Novidades»: quando aparece e o que mostra. Nunca abre a
/// janela nem toca nas UserDefaults reais.
final class WhatsNewTests: XCTestCase {
    private func release(_ version: String) -> WhatsNewRelease {
        WhatsNewRelease(version: version, items: [
            WhatsNewItem(id: "item-\(version)", symbol: "star", tint: .blue, title: "t", detail: "d"),
        ])
    }

    private var releases: [WhatsNewRelease] { ["0.8.1", "0.8.0", "0.7.0"].map(release) }

    private func versions(lastSeen: String?, current: String, didOnboard: Bool = true) -> [String] {
        WhatsNew.pending(in: releases, lastSeen: lastSeen, current: current, didOnboard: didOnboard).map(\.version)
    }

    // MARK: - pending

    func testFreshInstallShowsNothing() {
        XCTAssertEqual(versions(lastSeen: nil, current: "0.8.1", didOnboard: false), [])
    }

    func testNoKeyButOnboardedShowsEverythingUpToCurrent() {
        XCTAssertEqual(versions(lastSeen: nil, current: "0.8.1"), ["0.8.1", "0.8.0", "0.7.0"])
    }

    func testSkippedVersionsAreJoinedNewestFirst() {
        XCTAssertEqual(versions(lastSeen: "0.7.0", current: "0.8.1"), ["0.8.1", "0.8.0"])
    }

    func testOnlyTheNewVersionAfterASingleStep() {
        XCTAssertEqual(versions(lastSeen: "0.8.0", current: "0.8.1"), ["0.8.1"])
    }

    func testSameVersionShowsNothing() {
        XCTAssertEqual(versions(lastSeen: "0.8.1", current: "0.8.1"), [])
    }

    func testDowngradeShowsNothing() {
        XCTAssertEqual(versions(lastSeen: "0.8.1", current: "0.7.0"), [])
    }

    func testVersionsAboveCurrentAreLeftOut() {
        XCTAssertEqual(versions(lastSeen: nil, current: "0.8.0"), ["0.8.0", "0.7.0"])
        XCTAssertEqual(versions(lastSeen: "0.6.0", current: "0.7.5"), ["0.7.0"])
    }

    func testOrderDoesNotDependOnTheOrderOfTheList() {
        let shuffled = ["0.7.0", "0.8.1", "0.8.0"].map(release)
        let result = WhatsNew.pending(in: shuffled, lastSeen: nil, current: "0.8.1", didOnboard: true)
        XCTAssertEqual(result.map(\.version), ["0.8.1", "0.8.0", "0.7.0"])
    }

    func testLeadingVAndTwoPartVersions() {
        XCTAssertEqual(versions(lastSeen: "v0.7.0", current: "v0.8.1"), ["0.8.1", "0.8.0"])
        XCTAssertEqual(versions(lastSeen: "0.7", current: "0.8"), ["0.8.0"])
        XCTAssertEqual(versions(lastSeen: "0.8", current: "0.8.0"), [])
    }

    // MARK: - lastSeenToStore

    func testStoresTheCurrentVersion() {
        XCTAssertEqual(WhatsNew.lastSeenToStore(stored: nil, current: "0.8.1"), "0.8.1")
        XCTAssertEqual(WhatsNew.lastSeenToStore(stored: "0.7.0", current: "0.8.1"), "0.8.1")
        XCTAssertEqual(WhatsNew.lastSeenToStore(stored: "0.8.1", current: "0.8.1"), "0.8.1")
    }

    func testStoredVersionNeverGoesDown() {
        XCTAssertEqual(WhatsNew.lastSeenToStore(stored: "0.8.1", current: "0.7.0"), "0.8.1")
    }

    func testDowngradeThenUpdateDoesNotShowEverythingAgain() {
        // 0.8.1 visto, volta à 0.7.0 (nada guardado a menos), atualiza outra vez para 0.8.1.
        let stored = WhatsNew.lastSeenToStore(stored: "0.8.1", current: "0.7.0")
        XCTAssertEqual(versions(lastSeen: stored, current: "0.8.1"), [])
    }

    // MARK: - debugOverride

    func testNoOverrideWithoutDebugVersion() {
        XCTAssertNil(WhatsNew.debugOverride(environment: [:]))
        XCTAssertNil(WhatsNew.debugOverride(environment: ["HONE_DEBUG_LAST_SEEN": "0.7.0"]))
    }

    func testDebugVersionNeverPersists() {
        let plain = WhatsNew.debugOverride(environment: ["HONE_DEBUG_VERSION": "0.8.1"])
        XCTAssertEqual(plain?.persists, false)
        XCTAssertNil(plain?.lastSeen)

        let seen = WhatsNew.debugOverride(environment: [
            "HONE_DEBUG_VERSION": "0.8.1", "HONE_DEBUG_LAST_SEEN": "0.7.0",
        ])
        XCTAssertEqual(seen?.persists, false)
        XCTAssertEqual(seen?.lastSeen, "0.7.0")
    }

    // MARK: - Conteúdo

    func testEveryReleaseHasOneToFourItems() {
        for release in WhatsNew.releases {
            XCTAssertTrue((1...4).contains(release.items.count),
                          "\(release.version) tem \(release.items.count) itens")
        }
    }

    func testReleasesAreUniqueAndNewestFirst() {
        let versions = WhatsNew.releases.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count)
        for (newer, older) in zip(versions, versions.dropFirst()) {
            XCTAssertTrue(Updater.isNewer(newer, than: older), "\(newer) devia vir antes de \(older)")
        }
    }

    func testItemIDsAreUnique() {
        let ids = WhatsNew.releases.flatMap(\.items).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testItemsHaveTextAndRealSymbols() {
        for item in WhatsNew.releases.flatMap(\.items) {
            XCTAssertFalse(item.title.isEmpty, item.id)
            XCTAssertFalse(item.detail.isEmpty, item.id)
            XCTAssertNotNil(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil),
                            "\(item.id): símbolo \(item.symbol) não existe")
        }
    }
}
