import XCTest
@testable import PlaybackCore

final class TriggerTests: XCTestCase {
    let ma3 = ConsoleTarget(name: "Main", host: "10.0.0.5", port: 8000, prefix: "gma3")

    func testCommandsForEachAction() {
        var lane = TriggerLane(page: 1, executor: 201)
        XCTAssertEqual(lane.title, "1.201 · Go+")
        XCTAssertEqual(lane.messages(for: nil, console: ma3), [OSCMessage("/gma3/cmd", [.string("Go+ Exec 1.201")])])
        lane.action = .goMinus;  XCTAssertEqual(lane.commandLine(), "Go- Exec 1.201")
        lane.action = .top;      XCTAssertEqual(lane.commandLine(), "Top Exec 1.201")
        lane.action = .off;      XCTAssertEqual(lane.commandLine(), "Off Exec 1.201")
        lane.action = .fader
        let m = Marker(time: Timecode(frameCount: 0, rate: .fps30), label: "Half", value: 50)
        XCTAssertEqual(lane.messages(for: m, console: ma3), [OSCMessage("/gma3/Page1/Fader201", [.int(50)])])
        lane.action = .custom
        lane.command = "Goto Cue {value} Exec {page}.{exec} \"{label}\""
        let cue = Marker(time: Timecode(frameCount: 0, rate: .fps30), label: "Drop", value: 7)
        XCTAssertEqual(lane.commandLine(for: cue), "Goto Cue 7 Exec 1.201 \"Drop\"")
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

    func testLanesAndTriggersSaveWithTheShow() throws {
        let lane = TriggerLane(page: 2, executor: 105, action: .fader)
        var show = Show(name: "x")
        show.triggerLanes = [lane]
        show.songs = [Song(title: "July", start: Timecode("00:10:00:00", rate: .fps30)!,
                           markers: [Marker(time: Timecode("00:10:05:00", rate: .fps30)!, label: "Up", laneID: lane.id, value: 80)])]
        let back = try JSONDecoder().decode(Show.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(back.triggerLanes, [lane])
        XCTAssertEqual(back.songs[0].markers[0].laneID, lane.id)
        XCTAssertEqual(back.songs[0].markers[0].value, 80)
    }
}
