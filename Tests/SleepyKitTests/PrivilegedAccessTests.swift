import XCTest
@testable import SleepyKit

/// O conteúdo da regra sudoers e a leitura do `sudo -l`. Nunca instala nada nem corre `sudo`.
final class PrivilegedAccessTests: XCTestCase {
    func testRuleHasExactlyTheFourCommands() {
        let content = PrivilegedAccess.ruleContent(user: "tiago")
        XCTAssertEqual(content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), [
            "tiago ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1",
            "tiago ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0",
            "tiago ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 1",
            "tiago ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0",
            "",
        ])
    }

    func testRuleHasNoWildcardsOrExtraPrivileges() {
        let content = PrivilegedAccess.ruleContent(user: "tiago")
        for forbidden in ["*", "ALL=(ALL)", "NOPASSWD: ALL", "?", "[", ",", "SETENV", "#"] {
            XCTAssertFalse(content.contains(forbidden), "a regra não pode conter \(forbidden)")
        }
        for line in content.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("tiago ALL=(root) NOPASSWD: /usr/bin/pmset -a "))
        }
    }

    // MARK: - listingAllowsWithoutPassword

    private let lowPower = "/usr/bin/pmset -a lowpowermode 1"

    /// A listagem real desta máquina (regra v1 + o `(ALL) ALL` de qualquer admin).
    private let v1Listing = """
    Matching Defaults entries for tiagof on IAU-Mac:
        env_reset, env_keep+=BLOCKSIZE, lecture_file=/etc/sudo_lecture, !log_allowed

    User tiagof may run the following commands on IAU-Mac:
        (ALL) ALL
        (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
        (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0

    """

    /// O caso que um simples `sudo -n -l <comando>` falha: o `(ALL) ALL` dá exit 0 a tudo.
    func testV1RuleDoesNotAllowLowPowerButStillAllowsDisableSleep() {
        XCTAssertFalse(PrivilegedAccess.listingAllowsWithoutPassword(v1Listing, command: lowPower))
        XCTAssertTrue(PrivilegedAccess.listingAllowsWithoutPassword(v1Listing, command: "/usr/bin/pmset -a disablesleep 1"))
    }

    func testV2RuleAllowsLowPower() {
        let listing = v1Listing + """
            (root) NOPASSWD: /usr/bin/pmset -a lowpowermode 1
            (root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0

        """
        XCTAssertTrue(PrivilegedAccess.listingAllowsWithoutPassword(listing, command: lowPower))
        XCTAssertTrue(PrivilegedAccess.listingAllowsWithoutPassword(listing, command: "/usr/bin/pmset -a lowpowermode 0"))
    }

    func testNoRulesAtAll() {
        XCTAssertFalse(PrivilegedAccess.listingAllowsWithoutPassword("", command: lowPower))
        XCTAssertFalse(PrivilegedAccess.listingAllowsWithoutPassword("    (ALL) ALL\n", command: lowPower))
    }

    func testLastMatchingRuleWinsLikeSudo() {
        let passwordAfter = """
            (root) NOPASSWD: /usr/bin/pmset -a lowpowermode 1
            (ALL) ALL
        """
        XCTAssertFalse(PrivilegedAccess.listingAllowsWithoutPassword(passwordAfter, command: lowPower))
        let noPasswordAfter = """
            (ALL) ALL
            (ALL) NOPASSWD: ALL
        """
        XCTAssertTrue(PrivilegedAccess.listingAllowsWithoutPassword(noPasswordAfter, command: lowPower))
    }

    func testTagsApplyWithinACommaList() {
        let listing = "    (root) NOPASSWD: /usr/bin/true, PASSWD: /usr/bin/pmset -a lowpowermode 1\n"
        XCTAssertFalse(PrivilegedAccess.listingAllowsWithoutPassword(listing, command: lowPower))
        let list = "    (root) NOPASSWD: /usr/bin/true, /usr/bin/pmset -a lowpowermode 1\n"
        XCTAssertTrue(PrivilegedAccess.listingAllowsWithoutPassword(list, command: lowPower))
    }

    func testOtherCommandsDoNotMatch() {
        let listing = "    (root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0\n"
        XCTAssertFalse(PrivilegedAccess.listingAllowsWithoutPassword(listing, command: lowPower))
        let tagged = "    (root) NOPASSWD: SETENV: /usr/bin/pmset -a lowpowermode 1\n"
        XCTAssertTrue(PrivilegedAccess.listingAllowsWithoutPassword(tagged, command: lowPower))
    }
}
