import Foundation
import Darwin
import SystemConfiguration
import PlaybackCore

/// A UDP socket: sending (with broadcast) and, when bound, listening.
final class UDPSocket: @unchecked Sendable {
    private let fd: Int32
    private var source: DispatchSourceRead?
    let port: UInt16?
    /// The network port it's tied to ("en7"), or nil when macOS chooses.
    let networkPort: String?

    /// Bound to `port` to listen, or unbound just to send. With `networkPort`, everything it
    /// sends goes out that port and it only hears what arrives on it; nil if that port isn't
    /// there right now.
    init?(listenOn port: UInt16? = nil, networkPort: String? = nil) {
        var index: UInt32 = 0
        if let networkPort {
            index = if_nametoindex(networkPort)
            guard index != 0 else { return nil }
        }
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        if index != 0 {
            // IP_BOUND_IF (25 in <netinet/in.h>): tie the socket to one interface.
            guard setsockopt(fd, IPPROTO_IP, 25, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                close(fd)
                return nil
            }
        }
        self.port = port
        self.networkPort = networkPort
        if let port {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: 0)   // any address
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard ok == 0 else { close(fd); return nil }
        }
    }

    deinit {
        source?.cancel()
        if source == nil { close(fd) }
    }

    /// Why the last send didn't leave this Mac, in plain words (nil when it went).
    private(set) var lastError: String?

    @discardableResult
    func send(_ bytes: [UInt8], to host: String, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            lastError = "\(host.isEmpty ? "No address" : host) isn't an IP address."
            return false
        }
        let sent = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent == bytes.count {
            lastError = nil
            return true
        }
        lastError = Self.explain(errno, host: host)
        return false
    }

    /// What a send error means for Caiden.
    static func explain(_ code: Int32, host: String) -> String {
        let system = String(cString: strerror(code))
        switch code {
        case EPERM, EACCES:
            return "macOS blocked it (\(system)). Allow Vivid Playback in System Settings › Privacy & Security › Local Network, and in the firewall."
        case EHOSTUNREACH, ENETUNREACH:
            return "No way to reach \(host) (\(system)). Check the network port and the address. On newer macOS, also allow Vivid Playback in Privacy & Security › Local Network."
        case EADDRNOTAVAIL:
            return "The chosen network port has no address right now (\(system))."
        default:
            return "Couldn't send to \(host): \(system)."
        }
    }

    /// Calls `handler` with each datagram and the sender's address, on `queue`.
    func listen(on queue: DispatchQueue, handler: @escaping ([UInt8], String) -> Void) {
        let fd = self.fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len) }
                }
            }
            guard n > 0 else { return }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
            handler(Array(buffer[0..<n]), String(cString: host))
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// This Mac's network ports that are up and have an IPv4 address, named as macOS names them.
    static func networkPorts() -> [NetworkPort] {
        var labels: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                if let bsd = SCNetworkInterfaceGetBSDName(i).map({ $0 as String }),
                   let name = SCNetworkInterfaceGetLocalizedDisplayName(i).map({ $0 as String }) {
                    labels[bsd] = name
                }
            }
        }
        var out: [NetworkPort] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(i.pointee.ifa_flags) & IFF_UP) != 0, (Int32(i.pointee.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: i.pointee.ifa_name)
            func numeric(_ addr: UnsafeMutablePointer<sockaddr>?) -> String {
                guard let addr else { return "" }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            // Netmasks can come back shortened (sa_len under 8): the missing bytes are zero.
            func mask(_ addr: UnsafeMutablePointer<sockaddr>?) -> String {
                guard let addr else { return "0.0.0.0" }
                let len = addr.pointee.sa_len == 0 ? 8 : Int(addr.pointee.sa_len)
                let raw = UnsafeRawPointer(addr)
                return (0..<4).map { k in 4 + k < len ? String(raw.load(fromByteOffset: 4 + k, as: UInt8.self)) : "0" }
                    .joined(separator: ".")
            }
            let address = numeric(sa)
            guard !address.isEmpty, !address.hasPrefix("169.254.") || labels[name] != nil else { continue }
            out.append(NetworkPort(name: name, label: labels[name] ?? name, address: address,
                                   netmask: mask(i.pointee.ifa_netmask)))
        }
        return out
    }

    /// This Mac's IPv4 addresses, for showing where to send OSC.
    static func localAddresses() -> [(interface: String, address: String)] {
        var out: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(i.pointee.ifa_flags) & IFF_UP) != 0, (Int32(i.pointee.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            out.append((String(cString: i.pointee.ifa_name), String(cString: host)))
        }
        return out
    }
}
