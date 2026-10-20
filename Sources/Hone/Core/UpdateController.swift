import SwiftUI
import AppKit

/// Observable façade the menu and Settings read: holds the latest found update,
/// runs checks, and kicks off the install. Matches Hone's `@Observable` style.
@MainActor
@Observable
final class UpdateChecker {
    var availableUpdate: UpdateInfo?
    var status: String = ""

    @ObservationIgnored private let controller = UpdateController()
    @ObservationIgnored private var lastBackgroundCheck: Date?
    @ObservationIgnored private var periodicTimer: Timer?

    /// Silent check; only surfaces a banner when something newer exists.
    func checkInBackground() {
        guard Updater.autoCheckEnabled,
              UpdateSchedule.isDue(lastCheck: lastBackgroundCheck, now: Date()) else { return }
        lastBackgroundCheck = Date()
        Updater.check { [weak self] info in
            // A failed request (offline, rate limit) returns nil: keep any banner
            // already showing instead of hiding it until the next check.
            guard let info else { return }
            Task { @MainActor in self?.availableUpdate = info }
        }
    }

    /// Checks on launch, then every few hours and after the Mac wakes, so a
    /// release published while Hone is running shows up without a relaunch.
    func startPeriodicChecks() {
        checkInBackground()
        let timer = Timer(timeInterval: UpdateSchedule.period, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInBackground() }
        }
        timer.tolerance = UpdateSchedule.period / 10
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network is rarely back the instant the lid opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + UpdateSchedule.wakeDelay) {
                MainActor.assumeIsolated { self?.checkInBackground() }
            }
        }
    }

    /// Manual check from Settings, with user-facing status text either way.
    func checkNow() {
        status = "A procurar…"
        availableUpdate = nil
        Updater.check { [weak self] info in
            Task { @MainActor in
                guard let self else { return }
                self.availableUpdate = info
                self.status = info.map { "Atualização disponível: \($0.version)." }
                    ?? "Estás na versão mais recente (\(Updater.currentVersion))."
            }
        }
    }

    func install() {
        guard let availableUpdate else { return }
        controller.start(availableUpdate)
    }
}

/// When the silent background checks run. Every wake from sleep asks too, so
/// the gap keeps a Mac that naps often from hitting the GitHub API each time.
enum UpdateSchedule {
    static let period: TimeInterval = 6 * 60 * 60
    static let minimumGap: TimeInterval = 60 * 60
    static let wakeDelay: TimeInterval = 30

    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= minimumGap
    }
}

/// Set right before Hone quits only to come straight back (one-click update,
/// or `build.sh` reinstalling). On that quit, embedded tools keep their state
/// armed (e.g. Sleepy's sleep block) instead of tearing it down. Cleared on launch.
enum RelaunchFlag {
    static let key = "relaunchingForUpdate"

    static func set() { UserDefaults.standard.set(true, forKey: key) }

    /// Reads and clears the flag.
    static func consume() -> Bool {
        let value = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return value
    }
}

/// One-click updater: downloads the release .zip, swaps the app bundle and relaunches.
final class UpdateController: NSObject {
    private var window: NSWindow?
    private let model = UpdateModel()
    private var pageURL: URL?

    func start(_ info: UpdateInfo) {
        // Without a .zip asset we can't self-install — open the download page instead.
        guard let zipURL = info.zipURL else {
            NSWorkspace.shared.open(info.pageURL)
            return
        }
        pageURL = info.pageURL
        model.status = "A transferir o Hone \(info.version)…"
        model.failed = false
        showWindow()
        URLSession.shared.downloadTask(with: zipURL) { [weak self] tmp, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let tmp, error == nil, (200..<300).contains(code) else {
                self.fail("Não foi possível transferir a atualização.")
                return
            }
            self.install(downloaded: tmp)
        }.resume()
    }

    // MARK: - Install

    private func install(downloaded tmp: URL) {
        DispatchQueue.main.async { self.model.status = "A instalar…" }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("HoneUpdate-\(UUID().uuidString)")
        let zip = work.appendingPathComponent("Hone.zip")
        let extractDir = work.appendingPathComponent("extract")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.moveItem(at: tmp, to: zip)
        } catch {
            fail("Falha ao preparar a atualização."); return
        }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, extractDir.path]
        do { try ditto.run(); ditto.waitUntilExit() } catch { fail("Falha ao extrair."); return }
        guard ditto.terminationStatus == 0, let newApp = findApp(in: extractDir) else {
            fail("O pacote transferido é inválido."); return
        }

        swapAndRelaunch(newApp: newApp)
    }

    private func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        for item in items {
            if let sub = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil),
               let app = sub.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }

    private func swapAndRelaunch(newApp: URL) {
        let dest = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Move the old bundle aside, copy the new one in; restore on failure so the
        // app is never left missing.
        let log = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hone/update.log").path
        let script = """
        #!/bin/bash
        unset HONE_DEBUG_VERSION
        NEW="\(newApp.path)"
        DEST="\(dest)"
        LOG="\(log)"
        BACKUP="$DEST.old-$$"
        echo "$(date) --- swap start NEW=$NEW DEST=$DEST" >> "$LOG"
        for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        sleep 0.3
        /usr/bin/xattr -dr com.apple.quarantine "$NEW" 2>/dev/null
        /bin/mv "$DEST" "$BACKUP" 2>/dev/null
        if /usr/bin/ditto "$NEW" "$DEST"; then
          /bin/rm -rf "$BACKUP"
          echo "$(date) ditto OK" >> "$LOG"
        else
          /bin/rm -rf "$DEST"; /bin/mv "$BACKUP" "$DEST"
          echo "$(date) ditto FAILED, restored backup" >> "$LOG"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        "$LSREG" -f "$DEST" 2>/dev/null
        sleep 0.5
        /usr/bin/open "$DEST"
        echo "$(date) open status=$? dest_exists=$([ -d "$DEST" ] && echo yes || echo no)" >> "$LOG"
        sleep 2
        if ! /usr/bin/pgrep -f "$DEST/Contents/MacOS/Hone" >/dev/null 2>&1; then
          echo "$(date) not up after open — launching binary directly" >> "$LOG"
          "$DEST/Contents/MacOS/Hone" >/dev/null 2>&1 &
        fi
        echo "$(date) done" >> "$LOG"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hone-update-\(UUID().uuidString).sh")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) }
        catch { fail("Falha ao preparar a instalação."); return }

        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = [scriptURL.path]
        do { try bash.run() } catch { fail("Falha ao instalar a atualização."); return }

        DispatchQueue.main.async { self.model.status = "A reiniciar…" }
        RelaunchFlag.set()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    // MARK: - Window

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Atualizar o Hone"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: UpdateView(model: model, openPage: { [weak self] in
                if let url = self?.pageURL { NSWorkspace.shared.open(url) }
            }))
            window = w
        }
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.center()
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.model.status = message
            self.model.failed = true
        }
    }
}

final class UpdateModel: ObservableObject {
    @Published var status = ""
    @Published var failed = false
}

struct UpdateView: View {
    @ObservedObject var model: UpdateModel
    var openPage: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if model.failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(model.status)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.failed {
                Button("Abrir página de transferência", action: openPage)
            }
        }
        .padding(24)
        .frame(width: 360, height: 170)
    }
}
