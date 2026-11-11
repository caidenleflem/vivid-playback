import XCTest
@testable import PlaybackCore

final class NetworkPortTests: XCTestCase {
    let wired = NetworkPort(name: "en7", label: "USB LAN", address: "10.0.0.12", netmask: "255.0.0.0")
    let artNet = NetworkPort(name: "en8", label: "Thunderbolt Ethernet", address: "2.0.0.5", netmask: "255.0.0.0")
    let wifi = NetworkPort(name: "en0", label: "Wi-Fi", address: "192.168.1.40", netmask: "255.255.255.0")

    func testNetworkAndBroadcast() {
        XCTAssertEqual(wired.network, "10.0.0.0/8")
        XCTAssertEqual(wired.broadcast, "10.255.255.255")
        XCTAssertEqual(wifi.broadcast, "192.168.1.255")
        XCTAssertEqual(artNet.broadcast, "2.255.255.255")
    }

    func testWhichPortReachesAConsole() {
        let ports = [wifi, wired, artNet]
        XCTAssertEqual(NetworkPort.port(for: "10.0.0.69", among: ports), wired)
        XCTAssertEqual(NetworkPort.port(for: "2.255.255.255", among: ports), artNet)
        XCTAssertEqual(NetworkPort.port(for: "192.168.1.255", among: ports), wifi)
        XCTAssertNil(NetworkPort.port(for: "172.16.0.9", among: ports))
        XCTAssertNil(NetworkPort.port(for: "255.255.255.255", among: ports), "goes out any port: no single answer")
    }

    func testMismatchIsReported() {
        XCTAssertNil(NetworkPort.mismatch(host: "10.0.0.69", port: wired))
        XCTAssertEqual(NetworkPort.mismatch(host: "2.255.255.255", port: wired),
                       "2.255.255.255 isn't on USB LAN's network (10.0.0.0/8).")
        XCTAssertNil(NetworkPort.mismatch(host: "255.255.255.255", port: wired), "the all-ones broadcast is fine anywhere")
        XCTAssertNil(NetworkPort.mismatch(host: "10.0.0.69", port: nil), "automatic: nothing to check")
        XCTAssertNil(NetworkPort.mismatch(host: "console.local", port: wired), "not an address: nothing to check")
    }

    func testParsing() {
        XCTAssertEqual(IPv4.parse("10.0.0.69"), 0x0A00_0045)
        XCTAssertNil(IPv4.parse("10.0.0"))
        XCTAssertNil(IPv4.parse("10.0.0.256"))
        XCTAssertNil(IPv4.parse("10..0.1"))
        XCTAssertNil(IPv4.parse("a.b.c.d"))
        XCTAssertEqual(IPv4.text(0xC0A8_01FF), "192.168.1.255")
    }

    func testConsolesFromOlderSettingsLoadOnAutomatic() throws {
        let old = #"{"id":"6B1C1D2E-0000-4000-8000-000000000001","name":"grandMA3","host":"10.0.0.69","port":8000,"prefix":"gma3","enabled":true}"#
        let c = try JSONDecoder().decode(ConsoleTarget.self, from: Data(old.utf8))
        XCTAssertNil(c.networkPort)
    }
}
