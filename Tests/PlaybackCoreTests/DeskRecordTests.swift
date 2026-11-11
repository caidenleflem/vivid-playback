import XCTest
@testable import PlaybackCore

final class DeskRecordTests: XCTestCase {
    func testOSCForms() {
        XCTAssertEqual(DeskGo.from(OSCMessage("/vivid/exec", [.string("1.201")])), DeskGo(page: 1, executor: 201, source: .osc))
        XCTAssertEqual(DeskGo.from(OSCMessage("/vivid/exec", [.string("201"), .string("4")])), DeskGo(executor: 201, cue: "4", source: .osc))
        XCTAssertEqual(DeskGo.from(OSCMessage("/vivid/exec", [.int(2), .int(101)])), DeskGo(page: 2, executor: 101, source: .osc))
        XCTAssertEqual(DeskGo.from(OSCMessage("/vivid/exec", [.float(203)])), DeskGo(executor: 203, source: .osc))
        XCTAssertNil(DeskGo.from(OSCMessage("/vivid/exec", [.int(0)])))          // released
        XCTAssertNil(DeskGo.from(OSCMessage("/vivid/go", [.string("1.201")])))   // that's Play
        XCTAssertNil(DeskGo.from(OSCMessage("/vivid/exec", [.string("x")])))
        // /vivid/exec isn't a transport command.
        XCTAssertNil(RemoteCommand.from(OSCMessage("/vivid/exec", [.string("1.201")])))
    }

    func testMSCGoInAMIDIMessageAndInAnEthernetPacket() {
        // GO cue 4 list 201: F0 7F 01 02 01 01 '4' 00 '2' '0' '1' F7
        let msc: [UInt8] = [0xF0, 0x7F, 0x01, 0x02, 0x01, 0x01, 0x34, 0x00, 0x32, 0x30, 0x31, 0xF7]
        XCTAssertEqual(DeskGo.from(msc: msc), DeskGo(executor: 201, cue: "4", source: .msc))
        // Over Ethernet: a header in front ("GMA\0MSC\0" and a length).
        let packet: [UInt8] = Array("GMA".utf8) + [0] + Array("MSC".utf8) + [0, 20, 0, 0, 0] + msc
        XCTAssertEqual(DeskGo.from(msc: packet), DeskGo(executor: 201, cue: "4", source: .msc))
        // Page and executor in the list: "1.201".
        let paged: [UInt8] = [0xF0, 0x7F, 0x7F, 0x02, 0x01, 0x01, 0x31, 0x00, 0x31, 0x2E, 0x32, 0x30, 0x31, 0x00, 0xF7]
        XCTAssertEqual(DeskGo.from(msc: paged), DeskGo(page: 1, executor: 201, cue: "1", source: .msc))
        // Not a GO (STOP = 02), or no list: nothing to record.
        XCTAssertNil(DeskGo.from(msc: [0xF0, 0x7F, 0x01, 0x02, 0x01, 0x02, 0x34, 0x00, 0x32, 0xF7]))
        XCTAssertNil(DeskGo.from(msc: [0xF0, 0x7F, 0x01, 0x02, 0x01, 0x01, 0x34, 0xF7]))
    }

    func testLaneMatchingAndEchoes() {
        let main = TriggerLane(name: "Main", page: 1, executor: 201)
        let video = TriggerLane(name: "Video", page: 2, executor: 101)
        let lanes = [main, video]
        XCTAssertEqual(DeskRecorder.lane(for: DeskGo(page: 1, executor: 201, source: .osc), in: lanes)?.id, main.id)
        XCTAssertEqual(DeskRecorder.lane(for: DeskGo(executor: 101, source: .osc), in: lanes)?.id, video.id)
        XCTAssertNil(DeskRecorder.lane(for: DeskGo(page: 3, executor: 201, source: .osc), in: lanes))
        // MSC "201.1" (executor.page) also finds 1.201.
        XCTAssertEqual(DeskRecorder.lane(for: DeskGo(page: 201, executor: 1, source: .msc), in: lanes)?.id, main.id)
        XCTAssertTrue(DeskRecorder.isDuplicate(frame: 105, existing: [100, 300]))
        XCTAssertFalse(DeskRecorder.isDuplicate(frame: 120, existing: [100, 300]))
    }
}
