import Foundation
import Darwin

/// A UDP socket: sending (with broadcast) and, when bound, listening.
final class UDPSocket: @unchecked Sendable {
    private let fd: Int32
    private var source: DispatchSourceRead?
    let port: UInt16?

    /// Bound to `port` to listen, or unbound just to send.
    init?(listenOn port: UInt16? = nil) {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        self.port = port
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

    @discardableResult
    func send(_ bytes: [UInt8], to host: String, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let sent = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == bytes.count
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
