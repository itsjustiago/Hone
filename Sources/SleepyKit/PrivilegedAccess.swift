import Foundation

/// Opcional: privilégio sem password para o toggle de `pmset disablesleep`.
///
/// O v1 corre cada toggle via `osascript … with administrator privileges`,
/// que pede Touch ID/password de cada vez. Isto instala um drop-in muito
/// restrito em `/etc/sudoers.d/sleepy` (um único prompt de admin, uma vez)
/// que deixa o utilizador atual correr *apenas* os quatro comandos exatos
/// `pmset -a disablesleep 0|1` e `pmset -a lowpowermode 0|1` sem password
/// (regra v2; a v1 só tinha os dois primeiros). Sem wildcards, mais nada — não
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
        sudoPmset(["-a", "disablesleep", on ? "1" : "0"])
    }

    /// Corre `pmset -a lowpowermode <0|1>` via sudo sem password. Bloqueia até
    /// acabar: fora do main. Devolve false (sem pedir nada) se a regra não o permite.
    static func setLowPowerMode(_ on: Bool) -> Bool {
        sudoPmset(["-a", "lowpowermode", on ? "1" : "0"])
    }

    /// `sudo -n`: nunca pede password, falha em vez disso.
    private static func sudoPmset(_ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", pmset] + arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// A regra instalada deixa correr `pmset -a lowpowermode 1` sem password?
    /// Falso para quem instalou a v1. Lê `sudo -n -l` (só leitura, sem prompt) e
    /// bloqueia até acabar: fora do main.
    ///
    /// Não basta o exit de `sudo -n -l <comando>`: num utilizador admin
    /// (`(ALL) ALL`) é 0 para qualquer comando, com ou sem NOPASSWD.
    static func allowsLowPowerMode() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let listing = String(data: data, encoding: .utf8) else { return false }
        return listingAllowsWithoutPassword(listing, command: "\(pmset) -a lowpowermode 1")
    }

    /// Lê a listagem do `sudo -l` e diz se `command` corre sem password. Pura.
    /// Como o sudo: ganha a última regra que bate (o comando exato ou `ALL`), e
    /// o `NOPASSWD:`/`PASSWD:` vale daí em diante na mesma linha.
    static func listingAllowsWithoutPassword(_ listing: String, command: String) -> Bool {
        var allowed = false
        for raw in listing.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Só as linhas de regra: "(root) NOPASSWD: /usr/bin/pmset …".
            guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { continue }
            line = String(line[line.index(after: close)...])
            var noPassword = false
            for item in line.split(separator: ",") {
                var spec = item.trimmingCharacters(in: .whitespaces)
                // Etiquetas (NOPASSWD:, PASSWD:, SETENV:…) antes do comando.
                while let colon = spec.firstIndex(of: ":"), spec[..<colon].allSatisfy({ $0.isUppercase || $0 == "_" }) {
                    switch spec[..<colon] {
                    case "NOPASSWD": noPassword = true
                    case "PASSWD": noPassword = false
                    default: break
                    }
                    spec = spec[spec.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                if spec == command || spec == "ALL" { allowed = noPassword }
            }
        }
        return allowed
    }

    /// O conteúdo do drop-in sudoers (v2): quatro linhas, os comandos exatos, sem
    /// wildcards. Puro, para testar.
    static func ruleContent(user: String) -> String {
        let commands = ["disablesleep 1", "disablesleep 0", "lowpowermode 1", "lowpowermode 0"]
        return commands.map { "\(user) ALL=(root) NOPASSWD: \(pmset) -a \($0)\n" }.joined()
    }

    /// Instala o drop-in sudoers. Mostra um prompt de admin nativo (uma vez).
    @discardableResult
    static func install() -> Bool {
        let content = ruleContent(user: NSUserName())
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
