import XCTest
@testable import PlaybackCore

final class TriggerTests: XCTestCase {
    let ma3 = ConsoleTarget(name: "Main", host: "10.0.0.5", port: 8000, prefix: "gma3")

    func testCommandsForEachAction() {
        var lane = TriggerLane(page: 1, executor: 201)
        XCTAssertEqual(lane.title, "1.201 · Go+")
        XCTAssertEqual(lane.messages(for: nil, console: ma3), [OSCMessage("/gma3/cmd", [.string("Go+ Page 1.201")])])
        lane.action = .goMinus;  XCTAssertEqual(lane.commandLine(), "Go- Page 1.201")
        lane.action = .top;      XCTAssertEqual(lane.commandLine(), "Top Page 1.201")
        lane.action = .off;      XCTAssertEqual(lane.commandLine(), "Off Page 1.201")
        lane.action = .fader
        let m = Marker(time: Timecode(frameCount: 0, rate: .fps30), label: "Half", value: 50)
        XCTAssertEqual(lane.messages(for: m, console: ma3), [OSCMessage("/gma3/Page1/Fader201", [.int(50)])])
        lane.action = .custom
        lane.command = "Goto Cue {value} Page {page}.{exec} \"{label}\""
        let cue = Marker(time: Timecode(frameCount: 0, rate: .fps30), label: "Drop", value: 7)
        XCTAssertEqual(lane.commandLine(for: cue), "Goto Cue 7 Page 1.201 \"Drop\"")
        lane.command = "  "
        XCTAssertTrue(lane.messages(for: cue, console: ma3).isEmpty, "an empty command sends nothing")
    }

    func testPrefixAndTargets() {
        let noPrefix = ConsoleTarget(host: "10.0.0.6", prefix: "")
        XCTAssertEqual(TriggerLane().messages(for: nil, console: noPrefix).first?.address, "/cmd")
        let slashy = ConsoleTarget(host: "10.0.0.6", prefix: "/ma3/")
        XCTAssertEqual(TriggerLane().messages(for: nil, console: slashy).first?.address, "/ma3/cmd")

        let backup = ConsoleTarget(name: "Backup", host: "10.0.0.7")
        let off = ConsoleTarget(name: "Off", host: "10.0.0.8", enabled: false)
        let blank = ConsoleTarget(name: "No IP", host: "")
        let all = [ma3, backup, off, blank]
        XCTAssertEqual(TriggerLane().targets(in: all).map(\.name), ["Main", "Backup"])
        XCTAssertEqual(TriggerLane(consoleIDs: [backup.id]).targets(in: all).map(\.name), ["Backup"])
    }

    func testSchedulerFiresWhatIsPlayedThrough() {
        let a = UUID(), b = UUID(), c = UUID()
        let triggers = [TriggerScheduler.Trigger(frame: 100, id: a), .init(frame: 103, id: b), .init(frame: 400, id: c)]
        var s = TriggerScheduler()
        XCTAssertEqual(s.advance(to: 98, running: true, triggers: triggers), [], "first look only arms")
        XCTAssertEqual(s.advance(to: 100, running: true, triggers: triggers), [a])
        XCTAssertEqual(s.advance(to: 100, running: true, triggers: triggers), [], "never twice")
        XCTAssertEqual(s.advance(to: 104, running: true, triggers: triggers), [b])
        // A locate forward past c doesn't fire it.
        XCTAssertEqual(s.advance(to: 450, running: true, triggers: triggers), [])
        // Loop back and play through again: fires again.
        XCTAssertEqual(s.advance(to: 95, running: true, triggers: triggers), [])
        XCTAssertEqual(s.advance(to: 101, running: true, triggers: triggers), [a])
        // Stopped: nothing, and resuming re-arms first.
        XCTAssertEqual(s.advance(to: 102, running: false, triggers: triggers), [])
        XCTAssertEqual(s.advance(to: 104, running: true, triggers: triggers), [])
    }

    func testLanesAndTriggersSaveWithTheSong() throws {
        let lane = TriggerLane(page: 2, executor: 105, action: .fader)
        var show = Show(name: "x")
        var song = Song(title: "July", start: Timecode("00:10:00:00", rate: .fps30)!,
                        markers: [Marker(time: Timecode("00:10:05:00", rate: .fps30)!, label: "Up", laneID: lane.id, value: 80)])
        song.triggerLanes = [lane]
        show.songs = [song]
        let back = try JSONDecoder().decode(Show.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(back.songs[0].triggerLanes, [lane])
        XCTAssertEqual(back.songs[0].markers[0].laneID, lane.id)
        XCTAssertEqual(back.songs[0].markers[0].value, 80)
    }
}

final class LanesPerSongTests: XCTestCase {
    func testShowWideLanesMoveToTheSongsThatUseThem() {
        let tc = Timecode("01:00:00:00", rate: .fps30)!
        let a = TriggerLane(name: "A", executor: 201), b = TriggerLane(name: "B", executor: 202)
        var show = Show(name: "x")
        show.triggerLanes = [a, b]
        show.songs = [
            Song(title: "One", start: tc, markers: [Marker(time: tc, label: "go", laneID: a.id)]),
            Song(title: "Two", start: tc, markers: [Marker(time: tc, label: "go", laneID: a.id),
                                                    Marker(time: tc, label: "go", laneID: b.id)]),
            Song(title: "Three", start: tc, markers: [Marker(time: tc, label: "plain")]),
        ]
        XCTAssertTrue(show.moveLanesToSongs())
        XCTAssertNil(show.triggerLanes)
        XCTAssertEqual(show.songs[0].triggerLanes, [a])
        XCTAssertEqual(show.songs[1].triggerLanes, [a, b])
        XCTAssertNil(show.songs[2].triggerLanes)
        XCTAssertFalse(show.moveLanesToSongs())
        // Songs saved before lanes existed still load.
        let back = try? JSONDecoder().decode(Show.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(back?.songs[1].triggerLanes?.count, 2)
    }

    func testCopyGivesANewLane() {
        let a = TriggerLane(name: "A", executor: 201, key: "1")
        let c = a.copy()
        XCTAssertNotEqual(c.id, a.id)
        XCTAssertEqual(c.name, "A")
        XCTAssertEqual(c.key, "1")
    }
}

final class LaneKeyAndWindowTests: XCTestCase {
    func testLaneKeys() {
        XCTAssertEqual(TriggerLane.normalizedKey("Q"), "q")
        XCTAssertEqual(TriggerLane.normalizedKey("1"), "1")
        XCTAssertNil(TriggerLane.normalizedKey("m"))
        XCTAssertNil(TriggerLane.normalizedKey("C"))
        XCTAssertNil(TriggerLane.normalizedKey(" "))
        XCTAssertNil(TriggerLane.normalizedKey("ab"))
        XCTAssertNil(TriggerLane.normalizedKey("\u{F702}"))   // an arrow key
        XCTAssertEqual(TriggerLane(key: "M").key, nil)
        let lanes = [TriggerLane(key: "1"), TriggerLane(key: "3")]
        XCTAssertEqual(TriggerLane.freeKey(in: lanes), "2")
        // Lanes saved before keys existed still load.
        let old = #"{"id":"\#(UUID().uuidString)","name":"","page":1,"executor":201,"action":"goPlus","consoleIDs":[],"color":0,"muted":false}"#
        let lane = try? JSONDecoder().decode(TriggerLane.self, from: Data(old.utf8))
        XCTAssertNotNil(lane)
        XCTAssertNil(lane?.key)
    }

    func testWindowZoomKeepsAnchorStill() {
        var w = TimelineWindow(length: 200)
        XCTAssertEqual(w.x(50, width: 1000), 250, accuracy: 1e-9)
        w.setZoom(4, around: 50)
        XCTAssertEqual(w.span, 50, accuracy: 1e-9)
        XCTAssertEqual(w.x(50, width: 1000), 250, accuracy: 1e-9)   // still under the pointer
        XCTAssertEqual(w.time(atX: 250, width: 1000), 50, accuracy: 1e-9)
        w.pan(by: 1000)
        XCTAssertEqual(w.end, 200, accuracy: 1e-9)                // clamped to the song
        w.pan(by: -1000)
        XCTAssertEqual(w.start, 0, accuracy: 1e-9)
        w.setZoom(0.1, around: 10)
        XCTAssertEqual(w.zoom, 1)
        w.setZoom(10_000, around: 10)
        XCTAssertEqual(w.zoom, TimelineWindow.maxZoom)
    }

    func testWindowFollowsThePlayhead() {
        var w = TimelineWindow(length: 100, zoom: 10, start: 0)   // 10 s span
        w.follow(5)
        XCTAssertEqual(w.start, 0)
        w.follow(9.5)
        XCTAssertEqual(w.start, 8.5, accuracy: 1e-9)
        w.follow(60)
        XCTAssertEqual(w.start, 55, accuracy: 1e-9)
        var whole = TimelineWindow(length: 100)
        whole.follow(99)
        XCTAssertEqual(whole.start, 0)
    }

    func testTickStepShrinksWithZoom() {
        let whole = TimelineWindow(length: 240)
        XCTAssertEqual(whole.tickStep(width: 1000), 30)
        let close = TimelineWindow(length: 240, zoom: 200)        // 1.2 s across
        XCTAssertLessThan(close.tickStep(width: 1000), 0.5)
    }
}

final class ExecutorLabelTests: XCTestCase {
    func testOneLabelPerExecutorWithTheMostUsedName() {
        let foh = UUID(), backup = UUID()
        let lanes = [
            TriggerLane(name: "Main cues", page: 1, executor: 201, consoleIDs: [foh]),
            TriggerLane(name: "Strobes", page: 1, executor: 202),
            TriggerLane(name: "Main", page: 1, executor: 201, consoleIDs: [backup]),
            TriggerLane(name: "Main cues", page: 1, executor: 201, consoleIDs: [foh]),
            TriggerLane(name: "  ", page: 1, executor: 203),          // no name: nothing to send
            TriggerLane(name: "Video", page: 2, executor: 101),
        ]
        let plan = ExecutorLabel.plan(lanes: lanes)
        XCTAssertEqual(plan.map(\.id), ["1.201", "1.202", "2.101"])
        XCTAssertEqual(plan[0].names, ["Main cues", "Main"])
        XCTAssertEqual(plan[0].name, "Main cues")
        XCTAssertTrue(plan[0].hasConflict)
        XCTAssertEqual(plan[0].laneCount, 3)
        XCTAssertEqual(Set(plan[0].consoleIDs), [foh, backup])
        XCTAssertEqual(plan[1].consoleIDs, [])                       // every console
        XCTAssertFalse(plan[1].hasConflict)
    }

    func testCommandKeepsTheCommandLineIntact() {
        var label = ExecutorLabel(page: 1, executor: 201, names: ["x"], name: "Big \"look\" ", consoleIDs: [], laneCount: 1)
        XCTAssertEqual(label.command(template: ExecutorLabel.defaultTemplate), "Label Page 1.201 \"Big 'look'\"")
        label.name = "Verse"
        XCTAssertEqual(label.command(template: "Label Page {page}.{exec} \"{name}\""), "Label Page 1.201 \"Verse\"")
    }
}
