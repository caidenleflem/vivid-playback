import XCTest
@testable import PlaybackCore

final class DeskSequenceTests: XCTestCase {
    func event(_ args: [String]) -> DeskSequenceEvent? {
        DeskSequenceEvent.from(OSCMessage("/vivid/seq", args.map { .string($0) }))
    }

    func testReadsWhatThePluginSends() throws {
        let e = try XCTUnwrap(event(["3.201", "on", "5", "4", "3", "on", "Chorus"]))
        XCTAssertEqual(e.page, 3); XCTAssertEqual(e.executor, 201)
        XCTAssertTrue(e.isOn); XCTAssertTrue(e.wasOn)
        XCTAssertEqual(e.cue, 5); XCTAssertEqual(e.index, 4); XCTAssertEqual(e.previousIndex, 3)
        XCTAssertEqual(e.name, "Chorus")
        XCTAssertNil(event(["201", "on", "5", "4", "3", "on"]), "the plugin always sends the page")
        XCTAssertNil(DeskSequenceEvent.from(OSCMessage("/vivid/exec", [.string("3.201")])))
    }

    func testTheActionIsWhatTheSequenceDid() throws {
        func action(_ a: [String]) -> LaneAction? { event(a)?.action }
        XCTAssertEqual(action(["3.201", "on", "5", "4", "3", "on", "-"]), .goPlus)
        XCTAssertEqual(action(["3.201", "on", "3", "2", "3", "on", "-"]), .goMinus)
        XCTAssertEqual(action(["3.201", "on", "1", "0", "6", "on", "-"]), .top)
        XCTAssertEqual(action(["3.201", "on", "9", "8", "2", "on", "-"]), .gotoCue)
        XCTAssertEqual(action(["3.201", "off", "-", "-1", "4", "on", "-"]), .off)
        XCTAssertEqual(action(["3.201", "on", "5", "4", "4", "off", "-"]), .on, "back on where it was")
        XCTAssertEqual(action(["3.201", "on", "1", "0", "4", "off", "-"]), .gotoCue, "back on somewhere else")
    }

    func testLabelsAndPlayback() throws {
        let jump = try XCTUnwrap(event(["3.201", "on", "7.5", "8", "2", "on", "-"]))
        XCTAssertEqual(jump.label, "Cue 7.5")
        XCTAssertEqual(try XCTUnwrap(event(["3.201", "off", "-", "-1", "2", "on", "-"])).label, "Off")
        // A recorded jump plays back as a Goto on a Go+ lane.
        let lane = TriggerLane(page: 3, executor: 201)
        let m = Marker(time: Timecode(frameCount: 0, rate: .fps30), label: jump.label, laneID: lane.id, value: jump.cue, action: jump.action)
        XCTAssertEqual(lane.commandLine(for: m), "Goto Cue 7.5 Page 3.201")
        let back = Marker(time: Timecode(frameCount: 0, rate: .fps30), label: "x", laneID: lane.id, action: .goMinus)
        XCTAssertEqual(lane.messages(for: back, console: ConsoleTarget(host: "10.0.0.5")), [OSCMessage("/gma3/cmd", [.string("Go- Page 3.201")])])
        XCTAssertEqual(lane.commandLine(for: nil), "Go+ Page 3.201", "a trigger without its own action does the lane's")
    }

    /// What the plugin sent from a mock desk (Go+, Go-, Goto 5, Top, Off, On, and a second
    /// sequence coming on at cue 2), read back as the actions to record.
    func testThePluginsMessagesBecomeTheRightActions() {
        let sent = ["3.201,on,2,1,0,on,Look 2", "3.201,on,1,0,1,on,Look 1", "3.201,on,5,4,0,on,Look 5",
                    "3.201,on,1,0,4,on,Look 1", "3.201,off,1,0,0,on,Look 1", "3.201,on,1,0,0,off,Look 1",
                    "3.202,on,2,1,-1,off,Look 2"]
        let actions = sent.compactMap { event($0.split(separator: ",").map(String.init))?.action }
        XCTAssertEqual(actions, [.goPlus, .goMinus, .gotoCue, .top, .off, .on, .gotoCue])
    }

    func testOnlyTheExactExecutorsLane() {
        let a = TriggerLane(page: 1, executor: 201), b = TriggerLane(page: 3, executor: 201)
        let e = DeskSequenceEvent(page: 3, executor: 201, isOn: true, cue: 2, index: 1, previousIndex: 0, wasOn: true)
        XCTAssertEqual(DeskRecorder.lane(for: e, in: [a, b])?.id, b.id)
        XCTAssertNil(DeskRecorder.lane(for: e, in: [a]))
    }

    func testOlderTriggersLoadWithTheirLanesAction() throws {
        let old = #"{"id":"6B1C1D2E-0000-4000-8000-000000000001","time":"01:00:00:00@30","label":"Go+ 1"}"#
        if let m = try? JSONDecoder().decode(Marker.self, from: Data(old.utf8)) { XCTAssertNil(m.action) }
        let m = Marker(time: Timecode(frameCount: 0, rate: .fps30), label: "x", action: .gotoCue)
        XCTAssertEqual(try JSONDecoder().decode(Marker.self, from: JSONEncoder().encode(m)).action, .gotoCue)
    }

    func testPluginFiles() {
        let files = DeskPlugin.files(oscLine: 2)
        XCTAssertEqual(files.map(\.name), ["VividRecorder.xml", "VividRecorder.lua"])
        XCTAssertTrue(files[1].contents.contains("local OSC_LINE = 2"))
        XCTAssertTrue(files[1].contents.contains("/vivid/seq,ssssssss,"), "eight arguments: the stamp is last")
        XCTAssertTrue(files[0].contents.contains(#"FileName="VividRecorder.lua""#))
    }
}

final class DeskLabelTests: XCTestCase {
    func testReadsANameAndNamesEveryLaneForThatExecutor() throws {
        let l = try XCTUnwrap(DeskLabel.from(OSCMessage("/gma3/vivid/label", [.string("3.201"), .string("Verse wash")])))
        XCTAssertEqual(l, DeskLabel(page: 3, executor: 201, name: "Verse wash"))
        XCTAssertNil(DeskLabel.from(OSCMessage("/vivid/label", [.string("201"), .string("x")])), "needs the page")
        XCTAssertNil(DeskLabel.from(OSCMessage("/vivid/label", [.string("3.201"), .string(" ")])))

        let start = Timecode("01:00:00:00", rate: .fps30)!
        var a = Song(title: "A", start: start), b = Song(title: "B", start: start), c = Song(title: "C", start: start)
        a.triggerLanes = [TriggerLane(page: 3, executor: 201), TriggerLane(page: 3, executor: 202)]
        b.triggerLanes = [TriggerLane(name: "Old", page: 3, executor: 201)]
        c.triggerLanes = [TriggerLane(page: 1, executor: 201)]
        var songs = [a, b, c]
        let r = l.apply(to: &songs)
        XCTAssertEqual(r.lanes, 2); XCTAssertEqual(r.songs, 2)
        XCTAssertEqual(songs[0].triggerLanes?[0].name, "Verse wash")
        XCTAssertEqual(songs[0].triggerLanes?[1].name, "", "another executor isn't touched")
        XCTAssertEqual(songs[1].triggerLanes?[0].name, "Verse wash")
        XCTAssertEqual(songs[2].triggerLanes?[0].name, "", "same executor on another page isn't touched")
        XCTAssertEqual(l.apply(to: &songs).lanes, 0, "already named")
    }

    func testBothPluginsSave() {
        let names = DeskPlugin.allFiles().map(\.name)
        XCTAssertEqual(names, ["VividRecorder.xml", "VividRecorder.lua", "VividLabels.xml", "VividLabels.lua"])
        XCTAssertTrue(DeskPlugin.Labels.lua(oscLine: 3).contains("local OSC_LINE = 3"))
    }
}

final class DeskClockTests: XCTestCase {
    func testABurstHeldUpOnTheWayStillLandsWhereItHappened() {
        var clock = DeskClock()
        // The desk's clock is 1000 s behind this Mac's; messages take 3 ms at best.
        let offset = 1000.0, best = 0.003
        // A quiet message first, then 20 hits at the same instant that arrive spread over 400 ms.
        _ = clock.time(desk: 5.137, arrivedAt: 5.137 + offset + best)
        for i in 0..<20 {
            let at = clock.time(desk: 6.4219, arrivedAt: 6.4219 + offset + best + Double(i) * 0.02)
            XCTAssertEqual(at, 6.4219 + offset + best, accuracy: 1e-9, "hit \(i)")
        }
    }

    func testTheFastestMessageSetsTheOffset() {
        var clock = DeskClock()
        let delays = [0.040, 0.012, 0.090, 0.004, 0.030]
        var last = 0.0
        for (i, d) in delays.enumerated() { last = clock.time(desk: Double(i) + 0.5, arrivedAt: Double(i) + 0.5 + 100 + d) }
        XCTAssertEqual(last, 4.5 + 100 + 0.004, accuracy: 1e-9)
    }

    func testDriftIsFollowedAndARestartIsNoticed() {
        var clock = DeskClock()
        _ = clock.time(desk: 1.5, arrivedAt: 101.5)
        // 30 s later the clocks have drifted 5 ms apart: the old sample has aged out.
        XCTAssertEqual(clock.time(desk: 31.5, arrivedAt: 131.505), 131.505, accuracy: 1e-9)
        // The plugin restarted with a new clock.
        XCTAssertEqual(clock.time(desk: 0.25, arrivedAt: 140.0), 140.0, accuracy: 1e-9)
        XCTAssertEqual(clock.time(desk: 0.75, arrivedAt: 140.6), 140.5, accuracy: 1e-9)
    }

    func testNoStampOrWholeSecondsUseArrival() {
        var clock = DeskClock()
        XCTAssertEqual(clock.time(desk: nil, arrivedAt: 7), 7)
        for i in 0..<5 { _ = clock.time(desk: Double(i), arrivedAt: 50 + Double(i) + 0.3) }
        XCTAssertEqual(clock.time(desk: 9, arrivedAt: 70.4), 70.4, "a whole-second clock can't time hits")
    }

    func testTheStampIsRead() throws {
        let e = try XCTUnwrap(DeskSequenceEvent.from(OSCMessage("/vivid/seq", ["3.201", "on", "2", "1", "0", "on", "Look", "1234.5678"].map { .string($0) })))
        XCTAssertEqual(e.deskTime, 1234.5678)
        let old = try XCTUnwrap(DeskSequenceEvent.from(OSCMessage("/vivid/seq", ["3.201", "on", "2", "1", "0", "on", "Look"].map { .string($0) })))
        XCTAssertNil(old.deskTime, "an older plugin still works")
    }
}
