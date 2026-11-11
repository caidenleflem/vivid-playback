import XCTest
@testable import PlaybackCore

final class LevelsTests: XCTestCase {
    func testMeterRisesAtOnceAndFallsSteadily() {
        var m = MeterBallistics()
        m.update(peak: 1, fresh: true, now: 0)
        XCTAssertEqual(m.level, 1)
        m.update(peak: 0, fresh: true, now: 0.25)
        m.update(peak: 0, fresh: true, now: 0.5)
        XCTAssertEqual(m.level, 0.8, accuracy: 1e-4, "24 dB a second")
        XCTAssertEqual(m.hold, 1, "peak held")
    }

    func testNoNewAudioHoldsTheMeterStill() {
        var m = MeterBallistics()
        m.update(peak: 0.5, fresh: true, now: 0)
        let before = m.level
        m.update(peak: 0, fresh: false, now: 0.033)
        m.update(peak: 0, fresh: false, now: 0.066)
        XCTAssertEqual(m.level, before, "a gap between audio blocks isn't silence")
        m.update(peak: 0.5, fresh: true, now: 0.1)
        XCTAssertEqual(m.level, before, accuracy: 1e-6, "no dip and jump")
    }

    func testHoldFallsAfterAMoment() {
        var m = MeterBallistics()
        m.update(peak: 1, fresh: true, now: 0)
        for t in stride(from: 0.1, through: 1.4, by: 0.1) { m.update(peak: 0, fresh: true, now: t) }
        XCTAssertEqual(m.hold, 1)
        for t in stride(from: 1.5, through: 3.0, by: 0.1) { m.update(peak: 0, fresh: true, now: t) }
        XCTAssertLessThan(m.hold, 1)
        XCTAssertGreaterThanOrEqual(m.hold, m.level)
    }

    func testLimiterLeavesNormalLevelsAlone() {
        for x: Float in [0, 0.1, -0.5, 0.88, -0.89] { XCTAssertEqual(Mixer.limit(x), x) }
    }

    func testLimiterNeverPassesFullScale() {
        var last: Float = 0
        for i in 0...400 {
            let x = Float(i) / 100   // up to +12 dB
            let y = Mixer.limit(x)
            XCTAssertLessThan(y, 1.0001)
            XCTAssertGreaterThanOrEqual(y, last, "keeps rising, never folds back")
            XCTAssertEqual(Mixer.limit(-x), -y, "symmetric")
            last = y
        }
        XCTAssertEqual(Mixer.limit(0.8901), 0.8901, accuracy: 1e-4, "no step at the knee")
    }

    func testBoostedMasterIsLimitedButTimecodeIsNot() {
        let n = 64
        let b = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 0.9, count: n)],
                                timecode: [Float](repeating: 0.9, count: n))
        var head = Playhead(buffers: b, position: 0)
        let map = OutputMap(channelCount: 3, masterLeft: 0, masterRight: 1, timecode: 2)
        let ptrs = (0..<3).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { ptrs.forEach { $0.deallocate() } }
        let opt: [UnsafeMutablePointer<Float>?] = ptrs
        opt.withUnsafeBufferPointer { Mixer.render(&head, frames: n, into: $0, map: map, masterGain: 4, timecodeGain: 1) }
        XCTAssertLessThanOrEqual(ptrs[0][0], 1, "+12 dB on a loud master doesn't clip")
        XCTAssertGreaterThan(ptrs[0][0], 0.95)
        XCTAssertEqual(ptrs[2][0], 0.9, "timecode level untouched by the master boost")
        head = Playhead(buffers: b, position: 0)
        opt.withUnsafeBufferPointer { Mixer.render(&head, frames: n, into: $0, map: map, masterGain: 1, timecodeGain: 1) }
        XCTAssertEqual(ptrs[0][0], 0.9, "at 0 dB or below the limiter isn't in the path")
    }
}
