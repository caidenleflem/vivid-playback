import XCTest
@testable import PlaybackCore

/// A new edit of a song: the old master found in the new one, stretch by stretch.
final class EditAlignerTests: XCTestCase {
    let rate = 8000.0

    /// Music-like audio: a new note every 125 ms at a random level, decaying, over noise. The
    /// same seed gives the same music.
    func music(_ seconds: Double, seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func rnd() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        let n = Int(seconds * rate), note = Int(rate * 0.125)
        var out = [Float](repeating: 0, count: n)
        var level: Float = 0
        for i in 0..<n {
            if i % note == 0 { level = 0.05 + 0.95 * rnd() * rnd() }
            let decay = expf(-Float(i % note) / Float(note) * 3)
            out[i] = (rnd() * 2 - 1) * level * decay
        }
        return out
    }

    func secs(_ a: [Float], _ from: Double, _ to: Double) -> [Float] {
        Array(a[Int(from * rate)..<Int(to * rate)])
    }

    func align(_ old: [Float], _ new: [Float]) -> EditAligner.Result {
        EditAligner.align(old: old, oldRate: rate, new: new, newRate: rate)
    }

    func assertMoved(_ r: EditAligner.Result, _ t: Double, to expected: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard case .moved(let p) = r.place(t) else { return XCTFail("\(t): \(r.place(t))", file: file, line: line) }
        XCTAssertEqual(p, expected, accuracy: 0.003, "\(t) s", file: file, line: line)
    }

    func testTheSameMasterIsTheSame() {
        let a = music(40, seed: 1)
        let r = align(a, a)
        XCTAssertTrue(r.isSame, "\(r.segments)")
        assertMoved(r, 17.3, to: 17.3)
    }

    func testABarAddedMovesEverythingAfterIt() {
        let a = music(60, seed: 2), extra = music(4, seed: 99)
        let b = secs(a, 0, 20.5) + extra + secs(a, 20.5, 60)
        let r = align(a, b)
        XCTAssertEqual(r.segments.count, 2, "\(r.segments)")
        assertMoved(r, 10, to: 10)
        assertMoved(r, 20.3, to: 20.3)
        assertMoved(r, 20.8, to: 24.8)
        assertMoved(r, 45, to: 49)
        XCTAssertEqual(r.changes.count, 1, "\(r.changes)")
        if case .added(let d) = r.changes[0].kind { XCTAssertEqual(d, 4, accuracy: 0.02) } else { XCTFail("\(r.changes)") }
        XCTAssertEqual(r.changes[0].at, 20.5, accuracy: 0.05)
    }

    func testACutSectionMovesWhatFollowsEarlierAndItsTriggersToTheJoin() {
        let a = music(60, seed: 3)
        let b = secs(a, 0, 25) + secs(a, 31, 60)
        let r = align(a, b)
        assertMoved(r, 12, to: 12)
        assertMoved(r, 40, to: 34)
        guard case .cut(let j) = r.place(28) else { return XCTFail("\(r.place(28))") }
        XCTAssertEqual(j, 25, accuracy: 0.05)
        XCTAssertEqual(r.changes.count, 1, "\(r.changes)")
        if case .removed(let d) = r.changes[0].kind { XCTAssertEqual(d, 6, accuracy: 0.03) } else { XCTFail("\(r.changes)") }
    }

    func testALongerIntroShiftsTheWholeSong() {
        let a = music(40, seed: 4)
        let b = [Float](repeating: 0, count: Int(1.5 * rate)) + a
        let r = align(a, b)
        XCTAssertEqual(r.segments.count, 1, "\(r.segments)")
        assertMoved(r, 0.5, to: 2.0)
        assertMoved(r, 30, to: 31.5)
    }

    func testAShiftThatIsntOnAWholeFrame() {
        let a = music(30, seed: 5)
        let b = [Float](repeating: 0, count: Int(0.0137 * rate)) + a   // 13.7 ms later
        let r = align(a, b)
        assertMoved(r, 15, to: 15.0137)
    }

    func testARepeatedChorusDoesntPullTriggersOntoTheWrongRepeat() {
        let intro = music(8, seed: 10), chorus = music(8, seed: 11), verse = music(8, seed: 12)
        let bridge = music(8, seed: 13), outro = music(8, seed: 14), added = music(4, seed: 15)
        let a = intro + chorus + verse + chorus + outro        // chorus at 8 s and 24 s
        let b = intro + chorus + verse + added + chorus + outro // 4 s added before the second chorus
        _ = bridge
        let r = align(a, b)
        assertMoved(r, 10, to: 10)      // first chorus stays
        assertMoved(r, 27, to: 31)      // second chorus moves 4 s
        assertMoved(r, 35, to: 39)      // outro
    }

    func testAReplacedSectionIsSaidToHaveChangedAndItsTriggersAreAGuess() {
        let a = music(60, seed: 6)
        let b = secs(a, 0, 20) + music(7, seed: 77) + secs(a, 30, 60)   // 10 s replaced by 7 s
        let r = align(a, b)
        assertMoved(r, 10, to: 10)
        assertMoved(r, 40, to: 37)
        guard case .unsure = r.place(25) else { return XCTFail("\(r.place(25))") }
        XCTAssertTrue(r.changes.contains { if case .changed = $0.kind { return true } else { return false } }, "\(r.changes)")
    }

    func testDifferentSampleRates() {
        let a = music(30, seed: 7)
        var up = [Float](); up.reserveCapacity(a.count * 2)
        for x in a { up.append(x); up.append(x) }               // the same at 16 kHz
        let r = EditAligner.align(old: a, oldRate: rate, new: up, newRate: rate * 2)
        XCTAssertTrue(r.isSame, "\(r.segments)")
    }

    func testARemasterAtAnotherLevelStillLinesUp() {
        let a = music(40, seed: 16)
        var b = a.map { $0 * 0.7 }                                // 3 dB quieter
        b = secs(b, 0, 12) + music(2, seed: 17).map { $0 * 0.7 } + secs(b, 12, 40)
        let r = align(a, b)
        assertMoved(r, 6, to: 6)
        assertMoved(r, 30, to: 32)
    }

    func testDifferentMusicDoesntMatch() {
        let r = align(music(30, seed: 8), music(30, seed: 9))
        XCTAssertTrue(r.noMatch, "\(r.segments)")
    }
}

final class NewEditPlanTests: XCTestCase {
    let rate = FrameRate.fps30

    func song() -> Song {
        let start = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: rate)!
        var s = Song(title: "Diva", start: start, fileOffset: 2)
        s.markers = [
            Marker(time: start.adding(frames: 300), label: "before"),       // 10 s
            Marker(time: start.adding(frames: 900), label: "after"),        // 30 s
            Marker(time: start.adding(frames: 690), label: "in the cut"),   // 23 s
        ]
        s.beatGrid = BeatGrid(bpm: 120, downbeat: 0.25)
        return s
    }

    /// Old file: 2 s lead-in, then the song. New file: 3.5 s lead-in, and 4 s cut at song time 20.5–24.5.
    func result() -> EditAligner.Result {
        EditAligner.Result(segments: [
            .init(oldStart: 0, oldEnd: 22.5, shift: 1.5),
            .init(oldStart: 26.5, oldEnd: 60, shift: -2.5),
        ], oldLength: 60, newLength: 57.5)
    }

    func testPlanFollowsTheMusic() {
        let s = song()
        let plan = NewEditPlan(song: s, result: result())
        XCTAssertEqual(plan.fileOffset, 3.5, accuracy: 1e-9, "the start follows the longer lead-in")
        let ids = s.markers.map(\.id)
        XCTAssertEqual(plan.frames[ids[0]], 300, "before the cut: same song time")
        XCTAssertEqual(plan.frames[ids[1]], 780, "after the cut: 4 s earlier")
        XCTAssertEqual(plan.frames[ids[2]], 615, "in the cut: the join, 20.5 s")
        XCTAssertEqual(plan.unchanged, [ids[0]])
        XCTAssertEqual(plan.moved, [ids[1]])
        XCTAssertEqual(plan.cut, [ids[2]])
        XCTAssertEqual(plan.beatGrid?.downbeat ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(plan.changes.count, 1, "the lead-in is the start moving, not an edit")
        XCTAssertEqual(plan.changes.first?.at ?? 0, 20.5, accuracy: 1e-9)

        let applied = plan.apply(to: s)
        XCTAssertEqual(applied.fileOffset, 3.5, accuracy: 1e-9)
        XCTAssertEqual(applied.markers[1].time, s.start.adding(frames: 780))

        let text = plan.summary().joined(separator: "\n")
        XCTAssertTrue(text.contains("starts 1.50 s later"), text)
        XCTAssertTrue(text.contains("4.00 s cut at 0:20.50"), text)
        XCTAssertTrue(text.contains("1 trigger or marker moves, 1 stays put. 1 was in music that was cut"), text)
    }

    func testNoMatchMovesNothing() {
        let s = song()
        let plan = NewEditPlan(song: s, result: EditAligner.Result(segments: [], oldLength: 60, newLength: 60))
        XCTAssertTrue(plan.noMatch)
        XCTAssertEqual(plan.apply(to: s), s)
        XCTAssertTrue(plan.summary()[0].contains("doesn't sound like"))
    }

    func testTheSameMasterIsNothingToDo() {
        let s = song()
        let plan = NewEditPlan(song: s, result: EditAligner.Result(segments: [.init(oldStart: 0, oldEnd: 60, shift: 0)],
                                                                    oldLength: 60, newLength: 60))
        XCTAssertTrue(plan.isSame)
        XCTAssertEqual(plan.summary().first, "Same music at the same times. Nothing moves.")
    }
}
