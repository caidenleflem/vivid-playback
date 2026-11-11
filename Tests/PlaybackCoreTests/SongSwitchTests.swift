import XCTest
@testable import PlaybackCore

/// Song switches: running straight into the next song, and cutting to another without a click.
final class SongSwitchTests: XCTestCase {
    let stereo = OutputMap(channelCount: 3, masterLeft: 0, masterRight: 1, timecode: 2)

    /// Renders through a playhead in audio-sized blocks, like the audio thread.
    func run(_ head: inout Playhead, frames: Int, block: Int = 512, map: OutputMap? = nil,
             masterGain: Float = 1, loop: LoopRegion? = nil) -> [[Float]] {
        let map = map ?? stereo
        var out = [[Float]](repeating: [], count: map.channelCount)
        let ptrs = (0..<map.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { ptrs.forEach { $0.deallocate() } }
        let optional: [UnsafeMutablePointer<Float>?] = ptrs
        var done = 0
        while done < frames {
            let n = min(block, frames - done)
            optional.withUnsafeBufferPointer { buf in
                Mixer.render(&head, frames: n, into: buf, map: map, masterGain: masterGain, timecodeGain: 1, loop: loop)
            }
            for c in 0..<map.channelCount { out[c] += Array(UnsafeBufferPointer(start: ptrs[c], count: n)) }
            done += n
        }
        return out
    }

    /// A song whose master and timecode both count up from `base`, so every sample says where it came from.
    func song(_ base: Float, frames: Int) -> PlaybackBuffers {
        let ramp = (0..<frames).map { base + Float($0) }
        return PlaybackBuffers(sampleRate: 48_000, master: [ramp, ramp], timecode: ramp)
    }

    func testRunsStraightIntoTheNextSongWithNoGap() {
        let a = song(1000, frames: 1000), b = song(5000, frames: 3000)
        var head = Playhead(buffers: a, position: 700, next: b)
        // Odd block size so the song ends mid-block.
        let out = run(&head, frames: 900, block: 441)
        XCTAssertEqual(out[0][299], 1999, "last sample of the first song")
        XCTAssertEqual(out[0][300], 5000, "first sample of the next song, on the very next sample")
        XCTAssertEqual(out[2][299], 1999)
        XCTAssertEqual(out[2][300], 5000, "timecode moves on the same sample as the master")
        XCTAssertEqual(out[0][899], 5599)
        XCTAssertTrue(head.buffers === b)
        XCTAssertNil(head.next, "runs on into the next song once, then waits for the one after")
        XCTAssertEqual(head.advances, 1)
        XCTAssertEqual(head.position, 600)
    }

    func testEndingExactlyOnABlockBoundary() {
        let a = song(0, frames: 512), b = song(9000, frames: 1024)
        var head = Playhead(buffers: a, position: 0, next: b)
        let out = run(&head, frames: 1024, block: 512)
        XCTAssertEqual(out[0][511], 511)
        XCTAssertEqual(out[0][512], 9000)
        XCTAssertEqual(head.advances, 1)
    }

    func testWithNothingArmedItPlaysOnIntoSilence() {
        let a = song(1, frames: 100)
        var head = Playhead(buffers: a, position: 50)
        let out = run(&head, frames: 100)
        XCTAssertEqual(out[0][49], 100)
        XCTAssertEqual(out[0][50], 0)
        XCTAssertEqual(out[2][50], 0, "no timecode past the end")
        XCTAssertEqual(head.advances, 0)
        XCTAssertTrue(head.buffers === a)
    }

    func testLoopingNeverRunsOn() {
        let a = song(0, frames: 1000), b = song(9000, frames: 1000)
        var head = Playhead(buffers: a, position: 800, next: b)
        let out = run(&head, frames: 600, loop: LoopRegion(start: 800, end: 1000))
        XCTAssertEqual(out[0][200], 800, "loops back")
        XCTAssertEqual(head.advances, 0)
        XCTAssertTrue(head.next === b, "still armed for when the loop is taken off")
    }

    func testACutStartsTheNewSongAtOnceAndFadesTheOldOneUnderneath() {
        let loud = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 1, count: 48_000)],
                                   timecode: [Float](repeating: 0.7, count: 48_000))
        let quiet = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 0, count: 48_000)],
                                    timecode: [Float](repeating: -0.3, count: 48_000))
        var head = Playhead(buffers: loud, position: 10_000)
        _ = run(&head, frames: 256)
        head.cut(to: quiet, at: 0, fade: 384)
        XCTAssertTrue(head.isFading)
        let out = run(&head, frames: 1024, block: 128)
        XCTAssertEqual(out[2][0], -0.3, "the new song's timecode is out on the first sample, never faded or mixed")
        XCTAssertEqual(out[2][500], -0.3)
        XCTAssertEqual(out[0][0], 1, accuracy: 0.01, "the old master starts its fade at full level")
        for i in 1..<384 { XCTAssertLessThanOrEqual(out[0][i], out[0][i - 1], "falls smoothly, no step at block edges") }
        XCTAssertEqual(out[0][383], 0, accuracy: 0.01)
        XCTAssertEqual(out[0][384], 0, "gone after the fade")
        XCTAssertEqual(head.position, 1024)
        XCTAssertFalse(head.isFading)
    }

    func testACrossfadeNeverAddsUpPastFullLevel() {
        let full = { PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 1, count: 48_000)], timecode: nil) }
        let a = full(), b = full()
        var head = Playhead(buffers: a, position: 1000)
        head.cut(to: b, at: 0, fade: 384)
        let out = run(&head, frames: 1024, block: 100)
        for (i, v) in out[0].enumerated() { XCTAssertEqual(v, 1, accuracy: 1e-4, "frame \(i): no bump, no dip") }
    }

    func testTheNewSongRisesToFullLevelOverTheFade() {
        let silent = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 0, count: 48_000)], timecode: nil)
        let loud = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 1, count: 48_000)],
                                   timecode: [Float](repeating: 0.5, count: 48_000))
        var head = Playhead(buffers: silent, position: 1000)
        head.cut(to: loud, at: 0, fade: 384)
        let out = run(&head, frames: 800)
        XCTAssertEqual(out[0][0], 0, accuracy: 0.01)
        XCTAssertEqual(out[0][192], 0.5, accuracy: 0.01)
        XCTAssertEqual(out[0][384], 1, "full level once the fade is done")
        XCTAssertEqual(out[2][0], 0.5, "timecode at full level from the first sample")
    }

    func testTheFadeFollowsTheMasterLevel() {
        let a = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 1, count: 4000)], timecode: nil)
        var head = Playhead(buffers: a, position: 0)
        head.cut(to: nil, at: 0, fade: 100)
        let out = run(&head, frames: 200, masterGain: 0.5)
        XCTAssertEqual(out[0][0], 0.5, accuracy: 0.01)
        XCTAssertEqual(out[0][100], 0)
    }

    func testCuttingWithoutAFadeStopsDead() {
        let a = song(1, frames: 1000), b = song(9000, frames: 1000)
        var head = Playhead(buffers: a, position: 10)
        head.cut(to: b, at: 20, fade: 0)
        let out = run(&head, frames: 10)
        XCTAssertEqual(out[0][0], 9020)
        XCTAssertFalse(head.isFading)
    }

    func testStoppingDropsTheFade() {
        let a = song(1, frames: 1000)
        var head = Playhead(buffers: a, position: 10)
        head.cut(to: nil, at: 0, fade: 300)
        head.endFade()
        XCTAssertFalse(head.isFading)
        let out = run(&head, frames: 10)
        XCTAssertEqual(out[0][0], 0, "nothing of the old song when play resumes")
    }

    func testACutDisarmsWhatWasNext() {
        let a = song(0, frames: 100), b = song(1000, frames: 100), c = song(2000, frames: 100)
        var head = Playhead(buffers: a, position: 0, next: b)
        head.cut(to: c, at: 0, fade: 0)
        XCTAssertNil(head.next, "the song armed after the old one isn't the one after the new one")
    }

    func testNoFadeFromPastTheEnd() {
        let a = song(1, frames: 100), b = song(9000, frames: 1000)
        var head = Playhead(buffers: a, position: 150)
        head.cut(to: b, at: 0, fade: 50)
        XCTAssertFalse(head.isFading, "nothing was sounding, so nothing fades")
    }

    func testBothMasterSidesOnOneOutputAreSummedNotDoubled() {
        let b = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 0.4, count: 10), [Float](repeating: 0.2, count: 10)],
                                timecode: nil)
        var head = Playhead(buffers: b, position: 0)
        let out = run(&head, frames: 5, map: OutputMap(channelCount: 2, masterLeft: 0, masterRight: 0, timecode: nil))
        XCTAssertEqual(out[0][0], 0.3, accuracy: 1e-6)
    }

    func testCutFadeIsShort() {
        XCTAssertEqual(Mixer.cutFadeFrames(sampleRate: 48_000), 384)
        XCTAssertEqual(Mixer.cutFadeFrames(sampleRate: 96_000), 768)
    }
}
