import Foundation
import Darwin

/// Cumulative bytes of one network interface since boot.
struct InterfaceCounters: Equatable {
    var received: UInt64
    var sent: UInt64
}

/// Throughput between two readings, in bytes per second.
struct NetworkRates: Equatable {
    var download: Double
    var upload: Double
}

enum NetworkSampler {
    // MARK: Pure maths

    /// Walks the `NET_RT_IFLIST2` messages and keeps the Ethernet-type interfaces
    /// (Wi-Fi and Ethernet), by interface index. Loopback, VPN tunnels (`utun`,
    /// which would count the traffic twice) and bridges are left out.
    static func parse(_ buffer: UnsafeRawBufferPointer) -> [UInt16: InterfaceCounters] {
        var result: [UInt16: InterfaceCounters] = [:]
        var offset = 0
        // The message header (length, version, type) is 4 bytes.
        while offset + 4 <= buffer.count {
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length > 0, offset + length <= buffer.count else { break }
            defer { offset += length }
            guard buffer[offset + 3] == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size else { continue }
            let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            guard message.ifm_data.ifi_type == UInt8(IFT_ETHER),
                  message.ifm_flags & Int32(IFF_LOOPBACK) == 0 else { continue }
            result[message.ifm_index] = InterfaceCounters(received: message.ifm_data.ifi_ibytes,
                                                          sent: message.ifm_data.ifi_obytes)
        }
        return result
    }

    /// Bytes per second over the interval. Only interfaces present in both
    /// readings count, and a counter that went backwards (interface recreated)
    /// counts 0 in that direction.
    static func rates(previous: [UInt16: InterfaceCounters], current: [UInt16: InterfaceCounters],
                      seconds: Double) -> NetworkRates? {
        guard seconds > 0 else { return nil }
        var received = 0.0, sent = 0.0
        for (index, now) in current {
            guard let before = previous[index] else { continue }
            if now.received >= before.received { received += Double(now.received - before.received) }
            if now.sent >= before.sent { sent += Double(now.sent - before.sent) }
        }
        return NetworkRates(download: received / seconds, upload: sent / seconds)
    }

    // MARK: System

    /// Counters of every interface, or nil when the sysctl fails.
    static func read() -> [UInt16: InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // The list can grow between the size query and the read (ENOMEM): retry.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            if sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 {
                return buffer.withUnsafeBytes { parse(UnsafeRawBufferPointer(rebasing: $0.prefix(size))) }
            }
            if errno != ENOMEM { return nil }
        }
        return nil
    }
}
