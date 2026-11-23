import XCTest
@testable import PlaybackCore

final class HitSheetTests: XCTestCase {
    let rate = FrameRate.fps30

    func song() -> Song {
        let start = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: rate)!
        let main = TriggerLane(name: "Main cues", page: 3, executor: 201, action: .goPlus)
        let drop = TriggerLane(name: "", page: 1, executor: 1, action: .flash, sequence: "DIVA DROP")
        var muted = TriggerLane(name: "Strobes", page: 3, executor: 205, action: .goPlus)
        muted.muted = true
        var s = Song(title: "Diva", start: start)
        s.number = 4
        s.triggerLanes = [main, drop, muted]
        s.markers = [
            Marker(time: start.adding(frames: 90), label: "Hit, \"big\"", laneID: main.id),
            Marker(time: start.adding(frames: 30), label: "Verse", laneID: nil),
            Marker(time: start.adding(frames: 60), label: "", laneID: drop.id, action: .command, command: "Flash Off"),
            Marker(time: start.adding(frames: 120), label: "=SUM(A1)", laneID: main.id, value: 5, action: .gotoCue),
            Marker(time: start.adding(frames: 150), label: "", laneID: muted.id),
            Marker(time: start.adding(frames: -12), label: "Pre", laneID: main.id),
        ]
        return s
    }

    func testRowsInTimeOrderWithWhatEachDoes() {
        let rows = HitSheet.rows(for: song())
        XCTAssertEqual(rows.map(\.songTime), ["-0:00.40", "0:01.00", "0:02.00", "0:03.00", "0:04.00", "0:05.00"])
        XCTAssertEqual(rows[0].timecode, "00:59:59:18")
        XCTAssertEqual(rows[1].does, "Marker")
        XCTAssertTrue(rows[1].isMarker)
        XCTAssertEqual(rows[1].name, "Verse")
        XCTAssertEqual(rows[2].does, "Flash Off")
        XCTAssertEqual(rows[2].whereText, "Seq DIVA DROP")
        XCTAssertEqual(rows[2].command, "Flash Off Sequence \"DIVA DROP\"")
        XCTAssertEqual(rows[2].lane, "Sequence DIVA DROP · Flash", "an unnamed lane goes by its title")
        XCTAssertEqual(rows[3].does, "Go+")
        XCTAssertEqual(rows[3].command, "Go+ Page 3.201")
        XCTAssertEqual(rows[3].lane, "Main cues")
        XCTAssertEqual(rows[4].does, "Goto cue 5")
        XCTAssertEqual(rows[4].command, "Goto Cue 5 Page 3.201")
        XCTAssertTrue(rows[5].muted)
        XCTAssertNil(rows[0].barBeat, "no bars without a grid")
    }

    func testBarsAndBeatsOnceTheSongHasAGrid() {
        var s = song()
        s.beatGrid = BeatGrid(bpm: 120, downbeat: 0, beatsPerBar: 4)   // a beat every half second
        let rows = HitSheet.rows(for: s)
        XCTAssertEqual(rows[1].barBeat, "1.3", "1 s in: bar 1, beat 3")
        XCTAssertEqual(rows[3].barBeat, "2.3", "3 s in")
    }

    func testCSVQuotesAndKeepsFormulasAsText() {
        let csv = HitSheet.csv([song()])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Song,Timecode,Song time,Bar.Beat,Lane,Where,Does,Command,Name,Muted")
        XCTAssertTrue(lines.contains { $0.hasSuffix(",\"Hit, \"\"big\"\"\",") }, csv)
        XCTAssertTrue(lines.contains { $0.contains(",'=SUM(A1),") }, "a name that looks like a formula stays text")
        XCTAssertTrue(lines.contains { $0.hasPrefix("4. Diva,") })
        XCTAssertTrue(lines.contains { $0.hasSuffix(",muted") })
        XCTAssertEqual(lines.count, 1 + 6 + 1, "header, six rows, and the closing line break")
    }

    func testPrintablePage() {
        var empty = Song(title: "Intro <tape>", start: Timecode(hours: 2, minutes: 0, seconds: 0, frames: 0, rate: rate)!)
        empty.markers = []
        let html = HitSheet.html([song(), empty], showName: "Tour & Co")
        XCTAssertTrue(html.contains("Tour &amp; Co · Hit sheet"))
        XCTAssertTrue(html.contains("<h2>4. Diva</h2>"))
        XCTAssertTrue(html.contains("5 triggers"), "plain markers aren't counted as triggers")
        XCTAssertTrue(html.contains("Intro &lt;tape&gt;"))
        XCTAssertTrue(html.contains("Nothing on this song yet."))
        XCTAssertTrue(html.contains("Go+ (muted)"))
        XCTAssertFalse(html.contains("<th>Bar</th>"))
    }

    func testSongTime() {
        XCTAssertEqual(HitSheet.songTime(62.734), "1:02.73")
        XCTAssertEqual(HitSheet.songTime(0), "0:00.00")
        XCTAssertEqual(HitSheet.songTime(-0.001), "0:00.00")
        XCTAssertEqual(HitSheet.songTime(725), "12:05.00")
    }
}
