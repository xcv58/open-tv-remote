import Foundation

/// Sends Wake-on-LAN "magic packets" to turn on TVs whose network connection is asleep.
enum WakeOnLAN {
    /// Parses "aa:bb:cc:dd:ee:ff" or "aa-bb-cc-dd-ee-ff".
    static func macBytes(_ mac: String) -> [UInt8]? {
        let parts = mac.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }), bytes[0] & 1 == 0 else { return nil }
        return bytes
    }

    static func normalizedMAC(_ mac: String) -> String? {
        macBytes(mac.trimmingCharacters(in: .whitespacesAndNewlines))?
            .map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func magicPacket(mac: String) -> [UInt8]? {
        guard let bytes = macBytes(mac) else { return nil }
        return [UInt8](repeating: 0xFF, count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 }
    }

    /// Sends the packet straight to the TV's last known address and to the local broadcast address.
    /// Broadcast requires Apple's multicast entitlement on iOS. A successful send only means
    /// the network accepted a datagram; reconnecting to the TV confirms that it is awake.
    @discardableResult
    static func wake(mac: String, host: String) -> Bool {
        wake(mac: mac, host: host, send: send)
    }

    static func wake(mac: String, host: String, send: ([UInt8], String, UInt16) -> Bool) -> Bool {
        var address = in_addr()
        guard let packet = magicPacket(mac: mac), inet_pton(AF_INET, host, &address) == 1 else { return false }
        var accepted = false
        for target in [host, "255.255.255.255"] {
            for port: UInt16 in [9, 7] {
                // Evaluate every send, even if an earlier destination succeeded.
                let sent = send(packet, target, port)
                accepted = sent || accepted
            }
        }
        return accepted
    }

    private static func send(_ packet: [UInt8], _ host: String, _ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let count = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return count == packet.count
    }
}
