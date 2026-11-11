import XCTest
@testable import PlaybackCore

/// Master on one interface, timecode on another, played as one.
final class SplitOutputTests: XCTestCase {
    func testTimecodeLandsOnTheSecondInterfacesOutputs() {
        let r = OutputRouting(deviceUID: "rme", masterChannels: [1, 2], timecodeChannel: 2, timecodeDeviceUID: "motu")
        let m = OutputMap(routing: r, slots: [OutputSlot(uid: "rme", outputs: 8), OutputSlot(uid: "motu", outputs: 4)])
        XCTAssertEqual(m, OutputMap(channelCount: 12, masterLeft: 0, masterRight: 1, timecode: 9),
                       "the second interface's output 2 is the 10th output of the pair")
    }

    func testTimecodeOnOutputOneOfTheSecondInterfaceIsntTheMaster() {
        let r = OutputRouting(deviceUID: "a", masterChannels: [1, 2], timecodeChannel: 1, timecodeDeviceUID: "b")
        let m = OutputMap(routing: r, slots: [OutputSlot(uid: "a", outputs: 2), OutputSlot(uid: "b", outputs: 2)])
        XCTAssertEqual(m.timecode, 2, "same number, different interface: no clash")
    }

    func testTimecodeInterfaceMissingSendsNoTimecode() {
        let r = OutputRouting(deviceUID: "a", masterChannels: [1, 2], timecodeChannel: 3, timecodeDeviceUID: "b")
        let m = OutputMap(routing: r, slots: [OutputSlot(uid: "a", outputs: 8)])
        XCTAssertNil(m.timecode, "never moved onto the master's interface")
        XCTAssertEqual(m.masterLeft, 0)
    }

    func testAChannelTheSecondInterfaceDoesntHaveIsLeftOut() {
        let r = OutputRouting(deviceUID: "a", masterChannels: [1, 2], timecodeChannel: 5, timecodeDeviceUID: "b")
        let m = OutputMap(routing: r, slots: [OutputSlot(uid: "a", outputs: 8), OutputSlot(uid: "b", outputs: 2)])
        XCTAssertNil(m.timecode, "not spilled onto the first interface")
    }

    func testMasterChannelsStayOnTheFirstInterface() {
        let r = OutputRouting(deviceUID: "a", masterChannels: [3, 4], timecodeChannel: 1, timecodeDeviceUID: "b")
        let m = OutputMap(routing: r, slots: [OutputSlot(uid: "a", outputs: 2), OutputSlot(uid: "b", outputs: 8)])
        XCTAssertNil(m.masterLeft, "a master channel the master's interface doesn't have isn't taken from the other")
        XCTAssertEqual(m.timecode, 2)
    }

    func testSameInterfaceIsNotASplit() {
        let r = OutputRouting(deviceUID: "a", masterChannels: [1, 2], timecodeChannel: 3, timecodeDeviceUID: "a")
        XCTAssertFalse(r.splitsInterfaces)
        let m = OutputMap(routing: r, slots: [OutputSlot(uid: "a", outputs: 8)])
        XCTAssertEqual(m.timecode, 2)
        XCTAssertTrue(OutputRouting(deviceUID: nil, timecodeDeviceUID: "b").splitsInterfaces,
                      "default output for the master, a named interface for timecode")
    }

    func testOlderShowsLoadWithTimecodeOnTheMastersInterface() throws {
        let old = #"{"deviceUID":"a","masterChannels":[1,2],"timecodeChannel":3,"masterGainDB":0,"timecodeGainDB":-6}"#
        let r = try JSONDecoder().decode(OutputRouting.self, from: Data(old.utf8))
        XCTAssertNil(r.timecodeDeviceUID)
        XCTAssertFalse(r.splitsInterfaces)
        let back = try JSONDecoder().decode(OutputRouting.self, from: JSONEncoder().encode(
            OutputRouting(deviceUID: "a", timecodeChannel: 1, timecodeDeviceUID: "b")))
        XCTAssertEqual(back.timecodeDeviceUID, "b")
    }
}
