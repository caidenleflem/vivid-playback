import Foundation

/// One of this Mac's network ports (Ethernet, a USB adapter, Wi-Fi) and its IPv4 address.
public struct NetworkPort: Hashable, Sendable, Identifiable {
    /// The system's name for it ("en7"): what's saved, so the choice survives a restart.
    public var name: String
    /// What macOS calls it ("USB 10/100/1G/2.5G LAN", "Wi-Fi").
    public var label: String
    public var address: String
    public var netmask: String

    public var id: String { name }

    public init(name: String, label: String, address: String, netmask: String) {
        self.name = name
        self.label = label
        self.address = address
        self.netmask = netmask
    }

    /// The port's network as "10.0.0.x" style text for people: "10.0.0.0/8".
    public var network: String {
        guard let a = IPv4.parse(address), let m = IPv4.parse(netmask) else { return address }
        return "\(IPv4.text(a & m))/\(IPv4.prefixLength(m))"
    }

    /// The broadcast address on this port's network ("10.255.255.255" for 10.0.0.12/8).
    public var broadcast: String? {
        guard let a = IPv4.parse(address), let m = IPv4.parse(netmask) else { return nil }
        return IPv4.text((a & m) | ~m)
    }

    /// `host` is on this port's network (a broadcast to the network counts).
    public func reaches(_ host: String) -> Bool {
        guard let a = IPv4.parse(address), let m = IPv4.parse(netmask), let h = IPv4.parse(host) else { return false }
        if h == 0xFFFF_FFFF { return true }   // 255.255.255.255 goes out whichever port it's sent on
        return a & m == h & m
    }

    /// The port a host would be reached on: the first whose network holds it.
    public static func port(for host: String, among ports: [NetworkPort]) -> NetworkPort? {
        ports.first { $0.reaches(host) && IPv4.parse(host) != 0xFFFF_FFFF }
    }

    /// What to tell Caiden when `host` (or a broadcast) isn't on the network of the port chosen
    /// for it. Nil when it's fine or there's nothing to check.
    public static func mismatch(host: String, port: NetworkPort?) -> String? {
        guard let port, IPv4.parse(host) != nil, !port.reaches(host) else { return nil }
        return "\(host) isn't on \(port.label)'s network (\(port.network))."
    }
}

/// IPv4 addresses as numbers.
public enum IPv4 {
    public static func parse(_ text: String) -> UInt32? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let n = UInt32(p), n <= 255 else { return nil }
            v = v << 8 | n
        }
        return v
    }

    public static func text(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    public static func prefixLength(_ mask: UInt32) -> Int { mask.nonzeroBitCount }
}
