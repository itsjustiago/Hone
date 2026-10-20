import XCTest
import CoreAudio
@testable import SoundlyKit

final class AppGroupingTests: XCTestCase {
    private let chrome = RunningAppFacts(pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome",
                                         bundlePath: "/Applications/Google Chrome.app", isUIApp: true)
    private let chromeHelper = RunningAppFacts(pid: 101, bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper",
                                               bundlePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app",
                                               isUIApp: false)
    private let safari = RunningAppFacts(pid: 200, bundleID: "com.apple.Safari", name: "Safari",
                                         bundlePath: "/Applications/Safari.app", isUIApp: true)
    private let spotify = RunningAppFacts(pid: 300, bundleID: "com.spotify.client", name: "Spotify",
                                          bundlePath: "/Applications/Spotify.app", isUIApp: true)
    private let finder = RunningAppFacts(pid: 400, bundleID: "com.apple.finder", name: "Finder",
                                         bundlePath: "/System/Library/CoreServices/Finder.app", isUIApp: true)
    private let music = RunningAppFacts(pid: 500, bundleID: "com.apple.Music", name: "Música",
                                        bundlePath: "/System/Applications/Music.app", isUIApp: true)
    private let hone = RunningAppFacts(pid: 600, bundleID: "com.tiagof.hone", name: "Hone",
                                       bundlePath: "/Applications/Hone.app", isUIApp: true)

    private func process(_ object: AudioObjectID, pid: pid_t, bundleID: String? = nil, playing: Bool = false,
                         responsible: pid_t? = nil, path: String? = nil) -> AudioProcessFacts {
        AudioProcessFacts(objectID: object, pid: pid, bundleID: bundleID, isPlaying: playing,
                          responsiblePID: responsible, executablePath: path)
    }

    private func byPID(_ apps: [RunningAppFacts]) -> [pid_t: RunningAppFacts] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })
    }

    func testAppIsItsOwnOwner() {
        let owner = AudioAppGrouping.owner(of: process(1, pid: 300, bundleID: "com.spotify.client"), apps: byPID([spotify]))
        XCTAssertEqual(owner?.bundleID, "com.spotify.client")
    }

    func testHelperGoesToResponsibleApp() {
        // Safari's WebKit GPU process: not an app, not inside Safari.app, but Safari is responsible.
        let webkit = process(2, pid: 210, bundleID: "com.apple.WebKit.GPU", responsible: 200,
                             path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")
        XCTAssertEqual(AudioAppGrouping.owner(of: webkit, apps: byPID([safari]))?.bundleID, "com.apple.Safari")
    }

    func testHelperRegisteredAsBackgroundAppIsNotItsOwnOwner() {
        // The helper is known to Launch Services but `.prohibited`: falls through to its responsible app.
        let helper = process(3, pid: 101, bundleID: "com.google.Chrome.helper", responsible: 100)
        XCTAssertEqual(AudioAppGrouping.owner(of: helper, apps: byPID([chrome, chromeHelper]))?.bundleID,
                       "com.google.Chrome")
    }

    func testHelperRegisteredAsUIAppGoesToResponsibleApp() {
        // Electron: "Discord Helper (Renderer)" is a `.accessory` app of its own,
        // but Discord is responsible for it — seen on real hardware.
        let discord = RunningAppFacts(pid: 700, bundleID: "com.hnc.Discord", name: "Discord",
                                      bundlePath: "/Applications/Discord.app", isUIApp: true)
        let renderer = RunningAppFacts(pid: 701, bundleID: "com.hnc.Discord.helper.Renderer",
                                       name: "Discord Helper (Renderer)",
                                       bundlePath: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app",
                                       isUIApp: true)
        let helper = process(8, pid: 701, bundleID: "com.hnc.Discord.helper.Renderer", playing: true, responsible: 700)
        XCTAssertEqual(AudioAppGrouping.owner(of: helper, apps: byPID([discord, renderer]))?.bundleID, "com.hnc.Discord")
        let groups = AudioAppGrouping.groups(processes: [process(9, pid: 700, bundleID: "com.hnc.Discord", responsible: 700), helper],
                                             apps: [discord, renderer], hostPID: 1, hostBundleIDs: [])
        XCTAssertEqual(groups.map(\.owner.bundleID), ["com.hnc.Discord"])
        XCTAssertEqual(groups.first?.isPlaying, true)
    }

    func testAppResponsibleForItselfIsItsOwnOwner() {
        let spotifyProcess = process(30, pid: 300, bundleID: "com.spotify.client", responsible: 300)
        XCTAssertEqual(AudioAppGrouping.owner(of: spotifyProcess, apps: byPID([spotify]))?.bundleID, "com.spotify.client")
    }

    func testDisplayNameDropsInvisibleMarks() {
        XCTAssertEqual(AudioProcessReader.displayName("\u{200E}WhatsApp", fallback: "x"), "WhatsApp")
        XCTAssertEqual(AudioProcessReader.displayName(" \u{200F} ", fallback: "net.whatsapp.WhatsApp"), "net.whatsapp.WhatsApp")
    }

    func testHelperInsideBundleWithoutResponsiblePID() {
        let helper = process(4, pid: 102, path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
        XCTAssertEqual(AudioAppGrouping.owner(of: helper, apps: byPID([chrome]))?.bundleID, "com.google.Chrome")
    }

    func testBundleIDPrefixIsLastResortAndLongestWins() {
        let google = RunningAppFacts(pid: 50, bundleID: "com.google", name: "G", bundlePath: "/Applications/G.app", isUIApp: true)
        let helper = process(5, pid: 103, bundleID: "com.google.Chrome.helper.renderer")
        XCTAssertEqual(AudioAppGrouping.owner(of: helper, apps: byPID([google, chrome]))?.bundleID, "com.google.Chrome")
        // A bare prefix of a word doesn't count: "com.google.Chromecast" isn't Chrome's.
        let other = process(6, pid: 104, bundleID: "com.google.Chromecast")
        XCTAssertEqual(AudioAppGrouping.owner(of: other, apps: byPID([chrome]))?.bundleID, nil)
    }

    func testDaemonHasNoOwner() {
        let daemon = process(7, pid: 900, bundleID: "com.apple.audio.SystemSoundServer-OSX", responsible: 900,
                             path: "/System/Library/Frameworks/AudioToolbox.framework/AudioComponentRegistrar")
        XCTAssertNil(AudioAppGrouping.owner(of: daemon, apps: byPID([safari, spotify])))
    }

    func testOutermostAppBundle() {
        XCTAssertEqual(AudioAppGrouping.outermostAppBundle(in: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Y.app/Contents/MacOS/Y"),
                       "/Applications/Google Chrome.app")
        XCTAssertEqual(AudioAppGrouping.outermostAppBundle(in: "/Applications/Spotify.app/"), "/Applications/Spotify.app")
        XCTAssertNil(AudioAppGrouping.outermostAppBundle(in: "/usr/sbin/coreaudiod"))
    }

    func testListableExcludesSystemAgentsAndHost() {
        XCTAssertTrue(AudioAppGrouping.isListable(spotify, hostPID: 600, hostBundleIDs: ["com.tiagof.hone"]))
        XCTAssertTrue(AudioAppGrouping.isListable(music, hostPID: 600, hostBundleIDs: ["com.tiagof.hone"]),
                      "/System/Applications is user-facing")
        XCTAssertFalse(AudioAppGrouping.isListable(finder, hostPID: 600, hostBundleIDs: ["com.tiagof.hone"]))
        XCTAssertFalse(AudioAppGrouping.isListable(hone, hostPID: 600, hostBundleIDs: ["com.tiagof.hone"]))
        XCTAssertFalse(AudioAppGrouping.isListable(hone, hostPID: 1, hostBundleIDs: ["com.apple.dt.xctest.tool", "com.tiagof.hone"]),
                       "by bundle id too")
        XCTAssertFalse(AudioAppGrouping.isListable(chromeHelper, hostPID: 600, hostBundleIDs: []))
    }

    func testGroupsMergeHelpersUnderTheirApp() {
        let processes = [
            process(10, pid: 100, bundleID: "com.google.Chrome"),
            process(11, pid: 101, bundleID: "com.google.Chrome.helper", playing: true, responsible: 100),
            process(12, pid: 300, bundleID: "com.spotify.client"),
            process(13, pid: 400, bundleID: "com.apple.finder", playing: true),
            process(14, pid: 600, bundleID: "com.tiagof.hone", playing: true),
            process(15, pid: 900, bundleID: "com.apple.CoreSpeech"),
        ]
        let groups = AudioAppGrouping.groups(processes: processes,
                                             apps: [chrome, chromeHelper, spotify, finder, hone],
                                             hostPID: 600, hostBundleIDs: ["com.tiagof.hone"])
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.owner.bundleID, $0) })
        XCTAssertEqual(Set(byID.keys), ["com.google.Chrome", "com.spotify.client"])
        XCTAssertEqual(byID["com.google.Chrome"]?.objectIDs, [10, 11])
        XCTAssertEqual(byID["com.google.Chrome"]?.isPlaying, true, "a playing helper makes the app playing")
        XCTAssertEqual(byID["com.spotify.client"]?.isPlaying, false)
    }

    func testTwoInstancesShareOneGroup() {
        let second = RunningAppFacts(pid: 301, bundleID: "com.spotify.client", name: "Spotify",
                                     bundlePath: "/Users/x/Applications/Spotify.app", isUIApp: true)
        let groups = AudioAppGrouping.groups(processes: [process(20, pid: 301, bundleID: "com.spotify.client"),
                                                         process(21, pid: 300, bundleID: "com.spotify.client")],
                                             apps: [spotify, second], hostPID: 1, hostBundleIDs: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.owner.pid, 300, "lowest pid is the face of the group")
        XCTAssertEqual(groups.first?.objectIDs, [20, 21])
    }
}
