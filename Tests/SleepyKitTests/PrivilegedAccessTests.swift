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

    // MARK: - installScript (nunca corre)

    func testInstallScriptStagesInsideSudoersDir() throws {
        let script = try XCTUnwrap(PrivilegedAccess.installScript(user: "tiago"))
        XCTAssertTrue(PrivilegedAccess.stagingPath.hasPrefix("/etc/sudoers.d/"))
        // Com ponto no nome: o sudo ignora-o até ao `mv`.
        XCTAssertTrue((PrivilegedAccess.stagingPath as NSString).lastPathComponent.contains("."))
        XCTAssertTrue(script.contains("> '/etc/sudoers.d/.sleepy.new'"))
        XCTAssertFalse(script.contains(NSTemporaryDirectory()))
        XCTAssertFalse(script.contains("/tmp"))
    }

    /// Permissões e dono postos e validação com visudo, tudo antes do `mv`; se falhar, apaga.
    func testInstallScriptValidatesBeforeMoving() throws {
        let script = try XCTUnwrap(PrivilegedAccess.installScript(user: "tiago"))
        let mv = try XCTUnwrap(script.range(of: "/bin/mv -f '/etc/sudoers.d/.sleepy.new' '/etc/sudoers.d/sleepy'"))
        for step in ["/bin/chmod 0440 '/etc/sudoers.d/.sleepy.new'",
                     "/usr/sbin/chown root:wheel '/etc/sudoers.d/.sleepy.new'",
                     "/usr/sbin/visudo -cf '/etc/sudoers.d/.sleepy.new'"] {
            let range = try XCTUnwrap(script.range(of: step), step)
            XCTAssertLessThan(range.lowerBound, mv.lowerBound, "\(step) tem de vir antes do mv")
        }
        XCTAssertTrue(script.contains("else /bin/rm -f '/etc/sudoers.d/.sleepy.new'; exit 1; fi"))
    }

    /// O conteúdo escrito pelo root é a regra, linha a linha, entre plicas.
    func testInstallScriptWritesTheRuleLines() throws {
        let script = try XCTUnwrap(PrivilegedAccess.installScript(user: "tiago"))
        for line in PrivilegedAccess.ruleContent(user: "tiago").split(separator: "\n") {
            XCTAssertTrue(script.contains("'\(line)'"), "falta \(line)")
        }
    }

    func testValidUsers() {
        for user in ["tiago", "tiagof", "tiago.filipe", "t_f-2", "_mbsetupuser"] {
            XCTAssertTrue(PrivilegedAccess.isValidUser(user), user)
            XCTAssertNotNil(PrivilegedAccess.installScript(user: user), user)
        }
    }

    /// Qualquer coisa que pudesse mudar a regra ou sair das plicas é recusada.
    func testStrangeUsersAreRefused() {
        let bad = ["", "ALL", "tiago ALL", "tiago'", "ti\"ago", "a;b", "a\nb", "%admin", "+net", "#0",
                   "a,b", "a=b", "a*", "tiago\\", "$(id)", "`id`", "tiagó"]
        for user in bad {
            XCTAssertFalse(PrivilegedAccess.isValidUser(user), user)
            XCTAssertNil(PrivilegedAccess.installScript(user: user), user)
        }
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(PrivilegedAccess.shellQuote("a b"), "'a b'")
        XCTAssertEqual(PrivilegedAccess.shellQuote("it's"), "'it'\\''s'")
    }

    /// Barras e aspas escapadas para a string do AppleScript; o `\n` do printf chega ao sh intacto.
    func testAppleScriptEscaping() throws {
        let source = PrivilegedAccess.elevatedAppleScript(#"printf '%s\n' "x""#)
        XCTAssertEqual(source, #"do shell script "printf '%s\\n' \"x\"" with administrator privileges"#)
        let script = try XCTUnwrap(PrivilegedAccess.installScript(user: "tiago"))
        let full = PrivilegedAccess.elevatedAppleScript(script)
        // Só as aspas de abertura e fecho ficam sem escape.
        let body = full.dropFirst("do shell script \"".count).dropLast("\" with administrator privileges".count)
        XCTAssertFalse(body.replacingOccurrences(of: "\\\\", with: "").replacingOccurrences(of: "\\\"", with: "").contains("\""))
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

    // MARK: - Textos da regra na UI

    func testRuleButtonSaysUpdateOnlyWhenThereIsARule() {
        XCTAssertEqual(PrivilegedAccess.ruleButtonTitle(installed: true), "Atualizar regra…")
        XCTAssertEqual(PrivilegedAccess.ruleButtonTitle(installed: false), "Instalar regra…")
    }

    func testRuleNoticeDiffersByWhetherARuleExists() {
        let outdated = PrivilegedAccess.lowPowerRuleNotice(installed: true)
        let missing = PrivilegedAccess.lowPowerRuleNotice(installed: false)
        XCTAssertNotEqual(outdated.title, missing.title)
        XCTAssertTrue(outdated.title.contains("atualizar"))
        XCTAssertTrue(missing.title.contains("em falta"))
        for notice in [outdated, missing] {
            XCTAssertTrue(notice.detail.contains("Low Power Mode"))
            XCTAssertTrue(notice.detail.contains("admin"), "avisa que pede admin")
        }
    }
}
