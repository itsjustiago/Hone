import Foundation
import AppKit
import Darwin

/// One row of `top`. `cpu` is a percentage as `top` prints it (may exceed 100).
struct ProcessUsage: Equatable, Identifiable {
    var pid: Int32
    var cpu: Double
    var memoryBytes: UInt64
    /// Name as `top` printed it (truncated to 16 characters).
    var command: String
    var id: Int32 { pid }
}

enum TopParser {
    /// Parses the output of `top -stats pid,cpu,mem,command`. With several
    /// samples (`-l 2`) the last table wins — the first one's CPU is always 0.
    /// `excludingPID` drops `top` itself.
    static func parse(_ output: String, excludingPID: Int32? = nil) -> [ProcessUsage] {
        var tables: [[ProcessUsage]] = []
        var inTable = false
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Processes:") {
                inTable = false
            } else if trimmed.hasPrefix("PID") {
                tables.append([])
                inTable = true
            } else if inTable, !tables.isEmpty, let row = parseRow(trimmed), row.pid != excludingPID {
                tables[tables.count - 1].append(row)
            }
        }
        return tables.last ?? []
    }

    /// `411    27.6 1017M- WindowServer` — pid, cpu, mem, then the command, which
    /// may contain spaces.
    static func parseRow(_ line: String) -> ProcessUsage? {
        var rest = Substring(line)
        var tokens: [Substring] = []
        for _ in 0..<3 {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            tokens.append(rest[..<end])
            rest = rest[end...]
        }
        let command = rest.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty,
              let pid = Int32(tokens[0]),
              let cpu = Double(tokens[1].replacingOccurrences(of: ",", with: ".")),
              let memory = parseMemory(String(tokens[2])) else { return nil }
        return ProcessUsage(pid: pid, cpu: cpu, memoryBytes: memory, command: command)
    }

    /// "5968K+", "806M-", "1017M", "2,5G", "0B" → bytes.
    static func parseMemory(_ text: String) -> UInt64? {
        var body = Substring(text)
        while let last = body.last, last == "+" || last == "-" { body = body.dropLast() }
        guard let unit = body.last else { return nil }
        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        default:
            // No suffix: plain bytes.
            guard let plain = Double(body.replacingOccurrences(of: ",", with: ".")) else { return nil }
            return UInt64(max(0, plain))
        }
        guard let number = Double(body.dropLast().replacingOccurrences(of: ",", with: ".")), number >= 0 else {
            return nil
        }
        return UInt64(number * multiplier)
    }
}

/// Runs `/usr/bin/top` (setuid, so it sees processes of other users such as
/// WindowServer, which `proc_pidinfo` can't) off the main thread.
enum TopRunner {
    static let cpuArguments = ["-l", "2", "-s", "1", "-n", "8", "-o", "cpu", "-stats", "pid,cpu,mem,command"]
    static let memoryArguments = ["-l", "1", "-n", "8", "-o", "mem", "-stats", "pid,cpu,mem,command"]

    /// Raw rows (top 8), `top` itself excluded. Empty on failure, timeout or
    /// cancellation — in which case the `top` we launched is terminated.
    static func run(arguments: [String], timeout: TimeInterval = 5) async -> [ProcessUsage] {
        let job = Job()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: job.run(arguments: arguments, timeout: timeout))
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// Owns one `Process` so cancellation and the timeout can stop exactly it.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if running?.isRunning == true { running?.terminate() }
        }

        func run(arguments: [String], timeout: TimeInterval) -> [ProcessUsage] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
            task.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            task.environment = environment
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            task.standardInput = FileHandle.nullDevice

            lock.lock()
            if cancelled { lock.unlock(); return [] }
            do { try task.run() } catch { lock.unlock(); return [] }
            process = task
            lock.unlock()

            let pid = task.processIdentifier
            let watchdog = DispatchWorkItem { [weak self] in self?.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            // Read to EOF before waiting: waiting first deadlocks once the pipe fills.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            watchdog.cancel()
            lock.lock()
            process = nil
            lock.unlock()

            guard task.terminationReason == .exit, task.terminationStatus == 0 else { return [] }
            return TopParser.parse(String(decoding: data, as: UTF8.self), excludingPID: pid)
        }
    }
}

/// Resolves the full name of a process: `top` truncates to 16 characters.
enum ProcessNames {
    @MainActor
    static func name(pid: Int32, fallback: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        return fallback
    }
}
