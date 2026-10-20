import Foundation
import IOKit

// Read-only access to the fan speeds through the SMC (System Management
// Controller). No permissions or root needed. Nothing here ever writes a key.

/// `SMCKeyData` as the AppleSMC user client expects it: 80 bytes with C layout.
/// Swift doesn't pad a nested struct up to its stride, so the nested C structs
/// (version, power limits, key info) are flattened with explicit padding. A test
/// pins every offset.
struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    var key: UInt32 = 0                      // @0
    var versMajor: UInt8 = 0                 // @4
    var versMinor: UInt8 = 0                 // @5
    var versBuild: UInt8 = 0                 // @6
    var versReserved: UInt8 = 0              // @7
    var versRelease: UInt16 = 0              // @8
    var padVers: UInt16 = 0                  // @10
    var limitVersion: UInt16 = 0             // @12
    var limitLength: UInt16 = 0              // @14
    var cpuPLimit: UInt32 = 0                // @16
    var gpuPLimit: UInt32 = 0                // @20
    var memPLimit: UInt32 = 0                // @24
    var keyInfoDataSize: UInt32 = 0          // @28
    var keyInfoDataType: UInt32 = 0          // @32
    var keyInfoAttributes: UInt8 = 0         // @36
    var padKeyInfo: (UInt8, UInt8, UInt8) = (0, 0, 0)  // @37
    var result: UInt8 = 0                    // @40
    var status: UInt8 = 0                    // @41
    var data8: UInt8 = 0                     // @42
    var padData: UInt8 = 0                   // @43
    var data32: UInt32 = 0                   // @44
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)  // @48
}

/// Decoding of SMC values. Unsupported types give nil.
enum SMCValue {
    /// Four ASCII characters as a big-endian integer ("FNum" → 0x464E756D).
    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Inverse of `fourCC`: the four ASCII characters of a big-endian code.
    static func text(_ code: UInt32) -> String {
        String((0..<4).map { Character(UnicodeScalar(UInt8(truncatingIfNeeded: code >> UInt32(24 - 8 * $0)))) })
    }

    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        switch type {
        case fourCC("flt "):
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case fourCC("ui8 "):
            return bytes.first.map(Double.init)
        case fourCC("ui16"):
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case fourCC("ui32"):
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case fourCC("fpe2"):
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case fourCC("sp78"):
            // Signed 8.8 fixed point (classic temperature type).
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }
}

/// One fan: current speed and the range the firmware allows.
struct FanReading: Equatable {
    var name: String
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double

    /// Position inside the min–max range, 0…1 (drives the colour).
    var loadFraction: Double {
        maxRPM > minRPM ? clamp01((rpm - minRPM) / (maxRPM - minRPM)) : 0
    }

    /// rpm / max, 0…1 (drives the history).
    var historyFraction: Double {
        maxRPM > 0 ? clamp01(rpm / maxRPM) : 0
    }
}

enum FanMath {
    /// The fan spinning fastest, which is what the menu bar shows.
    static func fastest(_ fans: [FanReading]) -> FanReading? {
        fans.max { $0.rpm < $1.rpm }
    }
}

enum FanAvailability: Equatable {
    case available(count: Int)
    case noFans
    case unreadable

    /// Note for Settings; nil when available.
    var note: String? {
        switch self {
        case .available: return nil
        case .noFans: return "Este Mac não tem ventoinhas."
        case .unreadable: return "Não foi possível ler as ventoinhas."
        }
    }
}

/// Outcome of reading one SMC key. `missing` (result 0x84) is permanent, `failure` may pass.
enum SMCRead: Equatable {
    case value(Double)
    case missing
    case failure
}

/// What the SMC samplers need, so tests can inject a fake.
protocol SMCReader: AnyObject {
    func readValue(_ key: String) -> SMCRead
    /// Number of keys the SMC holds (`#KEY`).
    func keyCount() -> Int?
    /// The key at an index; the SMC keeps them sorted.
    func key(at index: Int) -> String?
    func close()
}

extension SMCReader {
    func keyCount() -> Int? { nil }
    func key(at index: Int) -> String? { nil }
}

/// Open connection to the AppleSMC user client.
final class SMCConnection: SMCReader {
    private var connection: io_connect_t = 0
    /// Type and size of each key never change: ask once.
    private var infoCache: [String: (type: UInt32, size: UInt32)] = [:]

    /// Opens the connection, or returns the `kern_return_t` that stopped it.
    static func open() -> Result<SMCConnection, SMCOpenError> {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return .failure(SMCOpenError(code: KERN_FAILURE, step: "AppleSMC não encontrado")) }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let code = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard code == KERN_SUCCESS else { return .failure(SMCOpenError(code: code, step: "IOServiceOpen")) }
        let smc = SMCConnection()
        smc.connection = connection
        return .success(smc)
    }

    deinit { close() }

    func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    /// The raw output, or the SMC result code when the call itself went through.
    private func call(_ input: inout SMCKeyData) -> (output: SMCKeyData, ok: Bool)? {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.size
        let code = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.size,
                                             &output, &outSize)
        guard code == KERN_SUCCESS else { return nil }
        return (output, output.result == 0)
    }

    private enum Info {
        case found(type: UInt32, size: UInt32)
        case missing
        case failure
    }

    private func info(for key: String) -> Info {
        if let cached = infoCache[key] { return .found(type: cached.type, size: cached.size) }
        var request = SMCKeyData()
        request.key = SMCValue.fourCC(key)
        request.data8 = 9
        guard let reply = call(&request) else { return .failure }
        if reply.output.result == 0x84 { return .missing }
        guard reply.ok, reply.output.keyInfoDataSize > 0, reply.output.keyInfoDataSize <= 32 else { return .failure }
        let found = (type: reply.output.keyInfoDataType, size: reply.output.keyInfoDataSize)
        infoCache[key] = found
        return .found(type: found.type, size: found.size)
    }

    /// Read-only: key info (cached), then the bytes.
    func readValue(_ key: String) -> SMCRead {
        switch info(for: key) {
        case .missing: return .missing
        case .failure: return .failure
        case .found(let type, let size):
            var request = SMCKeyData()
            request.key = SMCValue.fourCC(key)
            request.keyInfoDataSize = size
            request.data8 = 5
            guard let reply = call(&request), reply.ok else { return .failure }
            let bytes = withUnsafeBytes(of: reply.output.bytes) { Array($0.prefix(Int(size))) }
            // An unsupported type is reported like any other unreadable key.
            return SMCValue.decode(type: type, bytes: bytes).map(SMCRead.value) ?? .failure
        }
    }

    func keyCount() -> Int? {
        guard case .value(let count) = readValue("#KEY"), count >= 0, count <= Double(UInt32.max) else { return nil }
        return Int(count)
    }

    /// Read-only: command 8 gives the key stored at an index.
    func key(at index: Int) -> String? {
        guard index >= 0, index <= Int(UInt32.max) else { return nil }
        var request = SMCKeyData()
        request.data8 = 8
        request.data32 = UInt32(index)
        guard let reply = call(&request), reply.ok else { return nil }
        return SMCValue.text(reply.output.key)
    }
}

struct SMCOpenError: Error, Equatable {
    var code: kern_return_t
    var step: String
}

/// Reads fan speeds. Opens the SMC lazily, keeps the connection between
/// samples and retries transient failures with a growing delay (no log spam, no
/// hammering). Only "no such fan key" or zero fans is permanent.
final class FanSampler {
    private struct FanInfo { var name: String; var minRPM: Double; var maxRPM: Double }

    private let opener: () -> Result<SMCReader, SMCOpenError>
    private var connection: SMCReader?
    private var fans: [FanInfo] = []
    private var failures = 0
    private var retryAt = Date.distantPast
    private(set) var availability: FanAvailability = .unreadable

    /// Number of fans once known (0 until the first successful read).
    var fanCount: Int { fans.count }

    init(opener: @escaping () -> Result<SMCReader, SMCOpenError> = { SMCConnection.open().map { $0 as SMCReader } }) {
        self.opener = opener
    }

    func close() {
        connection?.close()
        connection = nil
    }

    /// Current readings, or nil when unavailable (check `availability`).
    func read(now: Date = Date()) -> [FanReading]? {
        if availability == .noFans { return nil }
        if connection == nil {
            guard now >= retryAt else { return nil }
            guard connect(now: now) else { return nil }
        }
        guard let connection, !fans.isEmpty else { return nil }
        var readings: [FanReading] = []
        for (index, info) in fans.enumerated() {
            guard case .value(let rpm) = connection.readValue("F\(index)Ac") else {
                fail(now: now)
                return nil
            }
            readings.append(FanReading(name: info.name, rpm: max(0, rpm), minRPM: info.minRPM, maxRPM: info.maxRPM))
        }
        failures = 0
        availability = .available(count: fans.count)
        return readings
    }

    private func connect(now: Date) -> Bool {
        guard case .success(let smc) = opener() else { fail(now: now); return false }
        switch smc.readValue("FNum") {
        case .missing:
            smc.close()
            availability = .noFans
            return false
        case .failure:
            smc.close()
            fail(now: now)
            return false
        case .value(let count) where count < 1:
            smc.close()
            availability = .noFans
            return false
        case .value(let count):
            // Min and max never change: read them once.
            func limit(_ key: String) -> Double {
                if case .value(let v) = smc.readValue(key) { return v }
                return 0
            }
            fans = (0..<Int(count)).map { index in
                FanInfo(name: "Ventoinha \(index + 1)", minRPM: limit("F\(index)Mn"), maxRPM: limit("F\(index)Mx"))
            }
            connection = smc
            availability = .available(count: fans.count)
            return true
        }
    }

    private func fail(now: Date) {
        connection?.close()
        connection = nil
        availability = .unreadable
        failures += 1
        retryAt = now.addingTimeInterval(min(60, pow(2, Double(failures))))
    }

    /// One-off check for Settings, with its own short-lived connection.
    static func probe() -> FanAvailability {
        let sampler = FanSampler()
        defer { sampler.close() }
        _ = sampler.read()
        return sampler.availability
    }
}
