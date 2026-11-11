import XCTest
@testable import PlaybackCore

final class BeatGridTests: XCTestCase {
    let sr = 8_000.0

    /// A drum-ish loop: a low thump on every beat (harder on beat 1 of the bar), a short
    /// noise tick on every off-beat eighth, and a quiet pad underneath.
    func loop(bpm: Double, seconds: Double, firstBeat: Double, accentBar: Bool = true,
              tempoChange: (at: Double, bpm: Double)? = nil) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * sr))
        var rng = SystemRandomNumberGenerator()
        for i in 0..<x.count { x[i] = 0.02 * Float(sin(2 * Double.pi * 220 * Double(i) / sr)) }
        var t = firstBeat
        var n = 0
        while t < seconds {
            let s = Int(t * sr)
            let loud: Float = (accentBar && n % 4 == 0) ? 0.9 : 0.5
            for k in 0..<Int(0.08 * sr) where s + k < x.count {
                let env = Float(exp(-Double(k) / (0.02 * sr)))
                x[s + k] += loud * env * Float(sin(2 * Double.pi * 60 * Double(k) / sr))
            }
            let current = (tempoChange.map { t >= $0.at ? $0.bpm : bpm }) ?? bpm
            let off = Int((t + 30 / current) * sr)
            for k in 0..<Int(0.01 * sr) where off + k < x.count {
                x[off + k] += 0.25 * Float(exp(-Double(k) / (0.002 * sr))) * Float(Int.random(in: -100...100, using: &rng)) / 100
            }
            t += 60 / current
            n += 1
        }
        return x
    }

    func testFindsTheTempoAndTheBeat() throws {
        let x = loop(bpm: 120, seconds: 40, firstBeat: 0.5)
        let g = try XCTUnwrap(BeatDetector.detect(x, sampleRate: sr))
        XCTAssertEqual(g.bpm, 120, accuracy: 0.05)
        // A beat lands where the thumps start (within a few milliseconds).
        let b = g.beat(at: 0.5)
        XCTAssertEqual(b, b.rounded(), accuracy: 0.03)
        XCTAssertGreaterThan(g.fit ?? 0, 0.9)
        XCTAssertNil(g.driftsAt)
    }

    func testOddTempoToAHundredth() throws {
        let x = loop(bpm: 127.35, seconds: 60, firstBeat: 0.31)
        let g = try XCTUnwrap(BeatDetector.detect(x, sampleRate: sr))
        XCTAssertEqual(g.bpm, 127.35, accuracy: 0.02)
        // Still on the beat at the end of the minute: no drift from a slightly wrong tempo.
        let lastBeat = 0.31 + 120 * 60 / 127.35
        let b = g.beat(at: lastBeat)
        XCTAssertEqual(b, b.rounded(), accuracy: 0.04)
    }

    func testBusyHatsDontDoubleTheTempo() throws {
        let x = loop(bpm: 140, seconds: 40, firstBeat: 0.2)
        let g = try XCTUnwrap(BeatDetector.detect(x, sampleRate: sr))
        XCTAssertEqual(g.bpm, 140, accuracy: 0.05)
    }

    func testBarOneIsTheSongsStartWhenABeatIsThere() throws {
        // The song starts 2 s into the file, right on a beat.
        let x = loop(bpm: 100, seconds: 40, firstBeat: 0.2, accentBar: false)
        let g = try XCTUnwrap(BeatDetector.detect(x, sampleRate: sr, fileOffset: 2.0))
        // 2.0 s is 0.2 + 3 beats of 0.6 s: a beat.
        XCTAssertEqual(g.downbeat, 0, accuracy: 0.015, "the song's start is a bar line")
        XCTAssertEqual(g.barBeat(at: g.downbeat).bar, 1)
        XCTAssertEqual(g.barBeat(at: g.downbeat).beat, 1, "and it's bar 1, beat 1")
    }

    func testBarOneFollowsTheAccentOtherwise() throws {
        // Accented thump every 4th beat starting at 0.5 + 1 beat; the song starts off the beat.
        let x = loop(bpm: 120, seconds: 40, firstBeat: 0.0)
        let g = try XCTUnwrap(BeatDetector.detect(x, sampleRate: sr, fileOffset: 0.25))
        // Accents (bar starts) are at file 0, 2, 4…: song time -0.25, 1.75…
        let b = g.beat(at: 1.75)
        XCTAssertEqual(b.truncatingRemainder(dividingBy: 4), 0, accuracy: 0.05)
    }

    func testSaysWhereTheTempoChanges() throws {
        let x = loop(bpm: 120, seconds: 60, firstBeat: 0.5, tempoChange: (at: 30, bpm: 126))
        let g = try XCTUnwrap(BeatDetector.detect(x, sampleRate: sr))
        let at = try XCTUnwrap(g.driftsAt, "a tempo change is reported, not bent over")
        XCTAssertGreaterThan(at, 20)
        XCTAssertLessThan(at, 42)
        XCTAssertLessThan(g.fit ?? 1, 0.9)
    }

    func testNothingToFindInSilenceOrAPad() {
        XCTAssertNil(BeatDetector.detect([Float](repeating: 0, count: Int(sr * 20)), sampleRate: sr))
        let pad = (0..<Int(sr * 20)).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / sr)) }
        XCTAssertNil(BeatDetector.detect(pad, sampleRate: sr))
    }

    // MARK: The grid

    func testBarsAndBeats() {
        let g = BeatGrid(bpm: 120, downbeat: 0)   // a beat every 0.5 s, a bar every 2 s
        XCTAssertEqual(g.barBeat(at: 0).bar, 1); XCTAssertEqual(g.barBeat(at: 0).beat, 1)
        XCTAssertEqual(g.barBeat(at: 1.6).bar, 1); XCTAssertEqual(g.barBeat(at: 1.6).beat, 4)
        XCTAssertEqual(g.barBeat(at: 2.0).bar, 2); XCTAssertEqual(g.barBeat(at: 2.0).beat, 1)
        XCTAssertEqual(g.barBeat(at: -0.5).bar, 0, "pre-roll counts back from bar 1")
        let beats = g.beats(from: 0, to: 4)
        XCTAssertEqual(beats.count, 9)
        XCTAssertEqual(beats.filter(\.isBar).map(\.time), [0, 2, 4])
        XCTAssertEqual(beats.filter(\.isBar).map(\.bar), [1, 2, 3])
    }

    func testBarOneIsTheFirstBarAtOrAfterTheStart() {
        let g = BeatGrid(bpm: 120, downbeat: -3.5)   // bars at -3.5, -1.5, 0.5…
        XCTAssertEqual(g.barBeat(at: 0.5).bar, 1)
        XCTAssertEqual(g.barBeat(at: 0.5).beat, 1)
        XCTAssertEqual(g.barBeat(at: 0).beat, 4)
    }

    func testSnapping() {
        let g = BeatGrid(bpm: 120, downbeat: 0.1)
        XCTAssertEqual(g.snap(0.33, to: .beat), 0.1 + 0.5 * 0, accuracy: 1e-9)
        XCTAssertEqual(g.snap(0.36, to: .beat), 0.6, accuracy: 1e-9)
        XCTAssertEqual(g.snap(0.36, to: .half), 0.35, accuracy: 1e-9)
        XCTAssertEqual(g.snap(0.36, to: .quarter), 0.35, accuracy: 1e-9)
        XCTAssertEqual(g.snap(1.0, to: .bar), 0.1, accuracy: 1e-9)
        XCTAssertEqual(g.snap(1.2, to: .bar), 2.1, accuracy: 1e-9)
        // To a whole frame at 30 fps.
        XCTAssertEqual(g.snapFrame(17, fps: 30, to: .beat), 18)   // 0.567 s → 0.6 s
    }

    func testFixingTheBarAndTheTempo() {
        var g = BeatGrid(bpm: 120, downbeat: 0, fit: 0.95)
        g.shiftBar(beats: 1)
        XCTAssertEqual(g.downbeat, 0.5)
        g.barStarts(at: 10.25)
        XCTAssertEqual(g.barBeat(at: 10.25).beat, 1)
        g.setTempo(100, keeping: 10.25)
        XCTAssertEqual(g.bpm, 100)
        XCTAssertEqual(g.barBeat(at: 10.25).beat, 1, "the grid stays put under the anchor")
        XCTAssertNil(g.fit, "typed in, not found")
        g.setTempo(5000, keeping: 0)
        XCTAssertEqual(g.bpm, 300)
        XCTAssertEqual(BeatGrid(bpm: 128).tempoText, "128 BPM")
        XCTAssertEqual(BeatGrid(bpm: 127.981).tempoText, "127.98 BPM")
    }

    func testDoubleAndHalfKeepBarOne() {
        var g = BeatGrid(bpm: 86, downbeat: 0.42)
        g.double()
        XCTAssertEqual(g.bpm, 172)
        XCTAssertEqual(g.downbeat, 0.42, accuracy: 1e-9)
        g.halve()
        XCTAssertEqual(g.bpm, 86)
        XCTAssertEqual(g.downbeat, 0.42, accuracy: 1e-9)
    }

    func testSongsWithoutAGridStillLoad() throws {
        let song = Song(title: "Intro", start: Timecode("01:00:00:00", rate: .fps30)!)
        var data = try JSONEncoder().encode(song)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "beatGrid")
        data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(Song.self, from: data).beatGrid)
    }
}
