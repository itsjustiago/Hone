import CoreAudio
import Foundation

/// A Core Audio call that failed, with the `OSStatus` it returned.
struct CoreAudioError: Error, CustomStringConvertible {
    var operation: String
    var status: OSStatus

    var description: String { "\(operation) falhou (\(Self.fourCC(status)))" }

    /// Core Audio statuses are usually four-character codes ('who?', '!dat').
    static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(status) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

/// Thin, synchronous readers over `AudioObjectGetPropertyData`. Main thread only
/// (never from the IOProc): every call is a round trip to `coreaudiod`.
enum AudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A fixed-size value (`UInt32`, `pid_t`, `Float64`, `AudioStreamBasicDescription`…).
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        as type: T.Type = T.self, initial: T) throws -> T {
        var address = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { raw in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioError(operation: "Ler \(selectorName(selector))", status: status) }
        return value
    }

    /// A variable-length array of fixed-size values (object lists, stream lists).
    static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             of type: T.Type, initial: T) throws -> [T] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(operation: "Medir \(selectorName(selector))", status: status) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: initial, count: count)
        status = values.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioError(operation: "Ler \(selectorName(selector))", status: status) }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// A `CFString` property (UIDs, bundle ids, names). Core Audio hands us a +1 reference.
    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError(operation: "Ler \(selectorName(selector))", status: status) }
        return value?.takeRetainedValue() as String? ?? ""
    }

    /// Number of streams the device has in `scope` (input or output).
    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        (try? readArray(device, kAudioDevicePropertyStreams, scope: scope, of: AudioObjectID.self, initial: 0).count) ?? 0
    }

    private static func selectorName(_ selector: AudioObjectPropertySelector) -> String {
        CoreAudioError.fourCC(OSStatus(bitPattern: selector))
    }
}

/// A property listener that stays registered until `remove()`. Core Audio needs
/// the very same block to unregister, so the handle keeps it. Callbacks arrive on
/// the main queue.
final class AudioPropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var isRegistered = false

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          handler: @escaping () -> Void) {
        self.object = object
        address = AudioObject.address(selector, scope)
        block = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        guard status == noErr else { return nil }
        isRegistered = true
    }

    func remove() {
        guard isRegistered else { return }
        isRegistered = false
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }

    deinit { remove() }
}
