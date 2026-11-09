import XCTest
@testable import PlaybackCore

final class MixerTests: XCTestCase {
    /// Renders `frames` frames through the mixer in blocks of `block`, like the audio thread.
    func run(_ b: PlaybackBuffers, map: OutputMap, frames: Int, block: Int = 512, start: Int = 0,
             masterGain: Float = 1, tcGain: Float = 1, loop: LoopRegion? = nil) -> [[Float]] {
        var out = [[Float]](repeating: [], count: map.channelCount)
        let ptrs = (0..<map.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { ptrs.forEach { $0.deallocate() } }
        let optional: [UnsafeMutablePointer<Float>?] = ptrs
        var pos = start
        var done = 0
        while done < frames {
            let n = min(block, frames - done)
            optional.withUnsafeBufferPointer { buf in
                pos = Mixer.render(b, position: pos, frames: n, into: buf, map: map, masterGain: masterGain, timecodeGain: tcGain, loop: loop)
            }
            for c in 0..<map.channelCount { out[c] += Array(UnsafeBufferPointer(start: ptrs[c], count: n)) }
            done += n
        }
        return out
    }

    func testRoutingFromOneBasedChannels() {
        let m = OutputMap(routing: OutputRouting(masterChannels: [1, 2], timecodeChannel: 8), channelCount: 8)
        XCTAssertEqual(m, OutputMap(channelCount: 8, masterLeft: 0, masterRight: 1, timecode: 7))
        let small = OutputMap(routing: OutputRouting(masterChannels: [1, 2], timecodeChannel: 8), channelCount: 2)
        XCTAssertNil(small.timecode, "a channel the interface doesn't have is left out, not moved")
        let clash = OutputMap(routing: OutputRouting(masterChannels: [1, 2], timecodeChannel: 2), channelCount: 4)
        XCTAssertNil(clash.timecode, "timecode never lands on a master channel")
    }

    func testRoutesGainsAndSilence() {
        let master = [[Float](repeating: 0.5, count: 1000), [Float](repeating: -0.5, count: 1000)]
        let tc = [Float](repeating: 0.25, count: 1000)
        let b = PlaybackBuffers(sampleRate: 48_000, master: master, timecode: tc)
        let map = OutputMap(channelCount: 4, masterLeft: 0, masterRight: 1, timecode: 3)
        let out = run(b, map: map, frames: 1200, masterGain: 0.5, tcGain: 2)
        XCTAssertEqual(out[0][10], 0.25)
        XCTAssertEqual(out[1][10], -0.25)
        XCTAssertEqual(out[2][10], 0, "unused channel is silent")
        XCTAssertEqual(out[3][10], 0.5, "timecode level is its own, not the master's")
        XCTAssertEqual(out[0][1100], 0, "silence past the end")
        XCTAssertEqual(out[3][1100], 0, "no timecode past the end")
    }

    func testMonoMasterGoesToBothSides() {
        let b = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 0.3, count: 100)], timecode: nil)
        let out = run(b, map: OutputMap(channelCount: 2, masterLeft: 0, masterRight: 1, timecode: nil), frames: 50)
        XCTAssertEqual(out[0][5], 0.3)
        XCTAssertEqual(out[1][5], 0.3)
    }

    func testMasterOnOneOutputIsSummedToMono() {
        let b = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 0.4, count: 10), [Float](repeating: 0.2, count: 10)],
                                timecode: [Float](repeating: 0.5, count: 10))
        let map = OutputMap(routing: OutputRouting(masterChannels: [1], timecodeChannel: 2), channelCount: 2)
        let out = run(b, map: map, frames: 5)
        XCTAssertEqual(out[0][0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(out[1][0], 0.5)
    }

    func testLoopJumpsBack() {
        let ramp = (0..<1000).map { Float($0) }
        let b = PlaybackBuffers(sampleRate: 48_000, master: [ramp, ramp], timecode: nil)
        let out = run(b, map: OutputMap(channelCount: 2, masterLeft: 0, masterRight: 1, timecode: nil),
                      frames: 300, start: 100, loop: LoopRegion(start: 100, end: 200))
        XCTAssertEqual(out[0][0], 100)
        XCTAssertEqual(out[0][99], 199)
        XCTAssertEqual(out[0][100], 100)
        XCTAssertEqual(out[0][250], 150)
    }

    /// The point of the whole engine: through the mixer, in audio-sized blocks, the timecode on
    /// its output reads the song's start exactly where the master reaches the song's start.
    func testTimecodeStaysLockedToTheMaster() {
        let sr = 48_000.0
        for rate in [FrameRate.fps30, .fps25, .fps29_97DF, .fps23_976] {
            let start = rate.isDropFrame ? Timecode("03:00:00;00", rate: rate)! : Timecode("03:00:00:00", rate: rate)!
            let song = Song(title: "Night Drive", start: start, fileOffset: 2.0)
            let frames = Int(sr * 8)
            var click = [Float](repeating: 0, count: frames)
            let songStartSample = Int(2.0 * sr)
            click[songStartSample] = 1   // the downbeat
            let b = PlaybackBuffers.prepare(song: song, sampleRate: sr, master: [click, click], timecode: nil)
            XCTAssertTrue(b.timecodeGenerated)
            let out = run(b, map: OutputMap(channelCount: 3, masterLeft: 0, masterRight: 1, timecode: 2), frames: frames, block: 441)
            let downbeat = out[0].firstIndex(of: 1)!
            let a = LTCAnalyzer.analyze(out[2], sampleRate: sr, expectedRate: rate)
            XCTAssertEqual(a.rate, rate)
            XCTAssertEqual(a.timecode(atSample: downbeat), start, "\(rate)")
            XCTAssertEqual(a.timecode(atSample: downbeat - 60), start.adding(frames: -1), "\(rate): the frame before starts just before the downbeat")
            XCTAssertTrue(a.jumps.isEmpty)
        }
    }

    func testFractionalOffsetLandsOnTheSample() {
        let sr = 48_000.0
        let start = Timecode("01:00:00:00", rate: .fps30)!
        let song = Song(title: "Overture", start: start, fileOffset: 1.234)
        let tc = PlaybackBuffers.generatedTimecode(for: song, sampleRate: sr, frames: Int(sr * 4))
        let a = LTCAnalyzer.analyze(tc, sampleRate: sr)
        let at = Int(1.234 * sr)
        XCTAssertEqual(a.timecode(atSample: at + 5), start)
        XCTAssertEqual(a.timecode(atSample: at - 60), start.adding(frames: -1))
    }
}
