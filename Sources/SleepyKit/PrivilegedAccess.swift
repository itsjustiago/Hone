import Foundation

/// Opcional: privilégio sem password para o toggle de `pmset disablesleep`.
///
/// O v1 corre cada toggle via `osascript … with administrator privileges`,
/// que pede Touch ID/password de cada vez. Isto instala um drop-in muito
/// restrito em `/etc/sudoers.d/sleepy` (um único prompt de admin, uma vez)
/// que deixa o utilizador atual correr *apenas* os dois comandos exatos
/// `pmset -a disablesleep 0|1` sem password. Sem wildcards, mais nada — não
/// é superfície de escalada de privilégios.
enum PrivilegedAccess {
    static let sudoersPath = "/etc/sudoers.d/sleepy"
    private static let pmset = "/usr/bin/pmset"
    private static let installedKey = "passwordlessInstalled"

    /// Se instalámos a regra sem password (só estado de UI; o caminho do toggle
    /// auto-corrige via um `sudo -n` em runtime, independentemente desta flag).
    static var isInstalled: Bool {
        get { SleepyDefaults.store.bool(forKey: installedKey) }
        set { SleepyDefaults.store.set(newValue, forKey: installedKey) }
    }

    /// Corre `pmset -a disablesleep <0|1>` via sudo sem password.
    /// Devolve false (sem pedir nada) quando a regra não está instalada.
    static func setDisableSleep(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Instala o drop-in sudoers. Mostra um prompt de admin nativo (uma vez).
    @discardableResult
    static func install() -> Bool {
        let user = NSUserName()
        let content = """
        \(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 1
        \(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0

        """
        let tmp = NSTemporaryDirectory() + "sleepy-sudoers-\(UUID().uuidString)"
        do { try content.write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Valida com visudo antes de instalar — um ficheiro inválido nunca pode
        // partir o sudo. Instala 0440 root:wheel (senão o sudo ignora-o).
        let shell = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(sudoersPath)'"
        let ok = runElevated(shell)
        if ok { isInstalled = true }
        return ok
    }

    /// Remove o drop-in sudoers. Mostra um prompt de admin nativo (uma vez).
    @discardableResult
    static func uninstall() -> Bool {
        let ok = runElevated("/bin/rm -f '\(sudoersPath)'")
        if ok { isInstalled = false }
        return ok
    }

    private static func runElevated(_ shell: String) -> Bool {
        let src = "do shell script \"\(shell)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            NSLog("Sleepy: ação privilegiada falhou: \(err)")
            return false
        }
        return true
    }
}
