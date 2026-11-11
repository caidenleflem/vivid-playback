import XCTest
@testable import PlaybackCore

final class MA3TimecodeTests: XCTestCase {
    /// The shape of a grandMA3 2.3.2.0 timecode export (cut down from a real one).
    let xml = """
    \u{FEFF}<?xml version="1.0" encoding="UTF-8"?>
    <GMA3 DataVersion="2.3.2.0">
        <Timecode Name="DIVA" Duration="3m43.33" OffsetTCSlot="1h50m00.00" TCSlot="1">
            <TrackGroup Play="" Rec="">
                <MarkerTrack Name="Marker"/>
                <Track Name="DIVA" Target="ShowData.DataPools.Default.Sequences.DIVA">
                    <TimeRange Duration="To End">
                        <CmdSubTrack>
                            <CmdEvent Name="Go+" Time="4.800" CueDestination="INTRO">
                                <RealtimeCmd Type="Key" ExecToken="Go+" ValCueDestination="0.5.1395.2000"/>
                            </CmdEvent>
                            <CmdEvent Name="Go+" Time="1m02.733" CueDestination="BEAT DROP">
                                <RealtimeCmd Type="Key" ExecToken="Go+" ValCueDestination="0.5.1395.4000"/>
                            </CmdEvent>
                        </CmdSubTrack>
                    </TimeRange>
                </Track>
                <Track Name="DIVA INTRO ZZZ 1" Target="ShowData.DataPools.Default.Sequences.DIVA INTRO ZZZ 1">
                    <TimeRange Duration="To End"><CmdSubTrack>
                        <CmdEvent Name="Go+" Time="2.000" CueDestination="Z"><RealtimeCmd ExecToken="Go+"/></CmdEvent>
                        <CmdEvent Name="Off" Time="10.500"><RealtimeCmd ExecToken="Off"/></CmdEvent>
                        <CmdEvent Name="Off" Time="20.000"><RealtimeCmd ExecToken="Off"/></CmdEvent>
                        <CmdEvent Name="Flash" Time="21.000"><RealtimeCmd ExecToken="Flash"/></CmdEvent>
                    </CmdSubTrack></TimeRange>
                </Track>
                <Track Target="ShowData.DataPools.Default.Sequences.82">
                    <TimeRange Duration="To End"><CmdSubTrack>
                        <CmdEvent Name="Go+" Time="3m10.967" CueDestination="END"><RealtimeCmd ExecToken="Go+"/></CmdEvent>
                    </CmdSubTrack></TimeRange>
                </Track>
                <Track Target="ShowData.DataPools.Default.Sequences.243"/>
                <Track Name="Macro" Target="ShowData.DataPools.Default.Macros.4">
                    <TimeRange><CmdSubTrack><CmdEvent Name="Go+" Time="1.0"/></CmdSubTrack></TimeRange>
                </Track>
            </TrackGroup>
        </Timecode>
    </GMA3>
    """

    func testReadsTheShow() throws {
        let shows = MA3Timecode.parse(Data(xml.utf8))
        XCTAssertEqual(shows.count, 1)
        let tc = try XCTUnwrap(shows.first)
        XCTAssertEqual(tc.name, "DIVA")
        XCTAssertEqual(tc.offset, 6600, accuracy: 1e-9, "1h50m00.00")
        XCTAssertEqual(tc.duration ?? 0, 223.33, accuracy: 1e-9)
        XCTAssertEqual(tc.tracks.map(\.sequence), ["DIVA", "DIVA INTRO ZZZ 1", "82"], "empty tracks left out")
        XCTAssertEqual(tc.otherTracks, 1, "the macro track is counted, not imported")
        let first = tc.tracks[0].events[1]
        XCTAssertEqual(first.time, 62.733, accuracy: 1e-9)
        XCTAssertEqual(first.action, .goPlus)
        XCTAssertEqual(first.cueName, "BEAT DROP")
        XCTAssertEqual(first.cueNumber, 4)
        XCTAssertNil(tc.tracks[2].name)
    }

    func testTimes() {
        XCTAssertEqual(MA3Timecode.seconds("1h50m00.00"), 6600)
        XCTAssertEqual(MA3Timecode.seconds("3m43.33") ?? 0, 223.33, accuracy: 1e-9)
        XCTAssertEqual(MA3Timecode.seconds("4.800"), 4.8)
        XCTAssertEqual(MA3Timecode.seconds("2h"), 7200)
        XCTAssertNil(MA3Timecode.seconds("To End"))
    }

    func song(start: String = "01:50:00:00", length: Double = 240) -> Song {
        var s = Song(title: "Diva", start: Timecode(start, rate: .fps30)!, fileOffset: 2)
        s.length = length
        return s
    }

    func testImportsLanesAndTriggersByTimecode() throws {
        let tc = try XCTUnwrap(MA3Timecode.parse(Data(xml.utf8)).first)
        var s = song()
        let r = MA3TimecodeImport.apply(tc, to: &s)
        XCTAssertEqual(r.lanesAdded, 3)
        XCTAssertEqual(r.triggers, 6)
        XCTAssertEqual(r.unsupported, ["Flash": 1])
        XCTAssertEqual(r.startDifference, 0, accuracy: 1e-9)
        let lanes = try XCTUnwrap(s.triggerLanes)
        XCTAssertEqual(lanes.map(\.name), ["DIVA", "DIVA INTRO ZZZ 1", "Sequence 82"])
        XCTAssertEqual(lanes[0].commandLine(), "Go+ Sequence \"DIVA\"")
        XCTAssertEqual(lanes[2].commandLine(), "Go+ Sequence 82")
        // BEAT DROP at 1:02.733 into the show: 01:51:02:22 at 30 fps.
        let drop = try XCTUnwrap(s.markers.first { $0.label == "BEAT DROP" })
        XCTAssertEqual(drop.time, Timecode("01:51:02:22", rate: .fps30))
        XCTAssertEqual(drop.laneID, lanes[0].id)
        // A lane does what most of its track does (Off here); the odd Go+ carries its own action.
        XCTAssertEqual(lanes[1].action, .off)
        let off = try XCTUnwrap(s.markers.first { $0.label == "Off" })
        XCTAssertNil(off.action)
        XCTAssertEqual(lanes[1].commandLine(for: off), "Off Sequence \"DIVA INTRO ZZZ 1\"")
        let go = try XCTUnwrap(s.markers.first { $0.label == "Z" })
        XCTAssertEqual(go.action, .goPlus)
        XCTAssertEqual(lanes[1].commandLine(for: go), "Go+ Sequence \"DIVA INTRO ZZZ 1\"")
    }

    func testImportingAgainAddsNothing() throws {
        let tc = try XCTUnwrap(MA3Timecode.parse(Data(xml.utf8)).first)
        var s = song()
        _ = MA3TimecodeImport.apply(tc, to: &s)
        let again = MA3TimecodeImport.apply(tc, to: &s)
        XCTAssertEqual(again.lanesAdded, 0)
        XCTAssertEqual(again.lanesReused, 3)
        XCTAssertEqual(again.triggers, 0)
        XCTAssertEqual(again.duplicates, 6)
    }

    func testADifferentStartIsReportedAndEventsOutsideTheSongAreLeftOut() throws {
        let tc = try XCTUnwrap(MA3Timecode.parse(Data(xml.utf8)).first)
        var s = song(start: "01:50:10:00", length: 60)   // starts 10 s later, a minute long
        let r = MA3TimecodeImport.apply(tc, to: &s)
        XCTAssertEqual(r.startDifference, -10, accuracy: 1e-9)
        // Placed by timecode: 4.8 s into the show is 5.2 s before this song's start (pre-roll is 2 s): outside.
        XCTAssertGreaterThan(r.outside, 0)
        XCTAssertNil(s.markers.first { $0.label == "INTRO" })
        XCTAssertNotNil(s.markers.first { $0.label == "BEAT DROP" }, "52.7 s into the song: inside")
    }

    func testFindsItsSong() throws {
        let tc = try XCTUnwrap(MA3Timecode.parse(Data(xml.utf8)).first)
        var a = song(); a.title = "Intro"; a.start = Timecode("01:40:00:00", rate: .fps30)!
        var b = song(); b.title = "DIVA "
        var c = song(); c.title = "Something else"; c.start = Timecode("02:10:00:00", rate: .fps30)!
        XCTAssertEqual(MA3TimecodeImport.song(for: tc, in: [a, b, c], selected: a.id)?.match, .name)
        XCTAssertEqual(MA3TimecodeImport.song(for: tc, in: [a, b, c], selected: a.id)?.id, b.id)
        b.title = "Diva (Remix)"
        XCTAssertEqual(MA3TimecodeImport.song(for: tc, in: [a, b, c], selected: a.id)?.id, b.id, "by its timecode")
        XCTAssertEqual(MA3TimecodeImport.song(for: tc, in: [a, b, c], selected: a.id)?.match, .timecode)
        b.start = Timecode("03:00:00:00", rate: .fps30)!
        XCTAssertEqual(MA3TimecodeImport.song(for: tc, in: [a, b, c], selected: c.id)?.match, .selected)
    }

    func testSequenceLanesStayOutOfExecutorLabels() {
        let lanes = [TriggerLane(name: "Wash", page: 1, executor: 201), TriggerLane(name: "DIVA", page: 0, executor: 0, sequence: "DIVA")]
        XCTAssertEqual(ExecutorLabel.plan(lanes: lanes).map(\.executor), [201])
        XCTAssertEqual(TriggerLane(page: 0, executor: 0, sequence: "82").title, "Sequence 82 · Go+")
    }
}
