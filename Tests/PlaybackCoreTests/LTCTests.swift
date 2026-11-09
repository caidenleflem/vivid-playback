import XCTest
@testable import PlaybackCore

final class LTCTests: XCTestCase {
    func testBitsLayoutAndParity() {
        let tc = Timecode("12:34:56:17", rate: .fps30)!
        let b = LTC.bits(for: tc)
        XCTAssertEqual(b.count, 80)
        XCTAssertEqual(Array(b[64...]), LTC.syncWord)
        XCTAssertEqual(b.filter { !$0 }.count % 2, 0, "polarity correction keeps zeros even")
        func v(_ s: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 | (b[s + $1] ? 1 << $1 : 0) } }
        XCTAssertEqual(v(0, 4), 7); XCTAssertEqual(v(8, 2), 1)
        XCTAssertEqual(v(16, 4), 6); XCTAssertEqual(v(24, 3), 5)
        XCTAssertEqual(v(32, 4), 4); XCTAssertEqual(v(40, 3), 3)
        XCTAssertEqual(v(48, 4), 2); XCTAssertEqual(v(56, 2), 1)
        XCTAssertFalse(b[10])
        XCTAssertTrue(LTC.bits(for: Timecode("00:10:00;00", rate: .fps29_97DF)!)[10])
    }

    func testRoundTripEveryRateAndSampleRate() {
        for rate in FrameRate.allCases {
            for sr in [44_100.0, 48_000.0, 96_000.0] {
                let start = rate.isDropFrame ? Timecode("03:00:59;20", rate: rate)! : Timecode("03:00:59:20", rate: rate)!
                let samples = LTC.render(start: start, frameCount: 120, sampleRate: sr)
                let a = LTCAnalyzer.analyze(samples, sampleRate: sr)
                XCTAssertEqual(a.rate, rate, "\(rate) at \(sr)")
                XCTAssertEqual(a.first, start, "\(rate) at \(sr)")
                XCTAssertEqual(a.last, start.adding(frames: 119), "\(rate) at \(sr)")
                XCTAssertEqual(a.firstSample, 0)
                XCTAssertTrue(a.jumps.isEmpty, "\(rate) at \(sr): \(a.jumps)")
                XCTAssertTrue(a.dropouts.isEmpty)
                XCTAssertEqual(a.atFileStart, start)
            }
        }
    }

    func testSurvivesInvertedQuietNoisyOffsetSignal() {
        let start = Timecode("04:00:00:00", rate: .fps30)!
        var seed: UInt64 = 42
        func noise() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 1000) / 1000 * 0.01 }
        let samples = LTC.render(start: start, frameCount: 90, sampleRate: 48_000, amplitude: 0.05).map { -$0 + 0.01 + noise() }
        let a = LTCAnalyzer.analyze(samples, sampleRate: 48_000)
        XCTAssertEqual(a.first, start)
        XCTAssertEqual(a.decodedFrames, 90)
        XCTAssertTrue(a.jumps.isEmpty)
    }

    func testLeadingSilenceCountsBackToFileStart() {
        let start = Timecode("02:00:00:00", rate: .fps25)!
        let silence = [Float](repeating: 0, count: 48_000)  // one second
        let samples = silence + LTC.render(start: start, frameCount: 75, sampleRate: 48_000)
        let a = LTCAnalyzer.analyze(samples, sampleRate: 48_000)
        XCTAssertEqual(a.first, start)
        XCTAssertEqual(a.atFileStart?.description, "01:59:59:00")
    }

    func testJumpsAndDropoutsAreFound() {
        let sr = 48_000.0
        let a1 = LTC.render(start: Timecode("01:00:00:00", rate: .fps30)!, frameCount: 60, sampleRate: sr)
        let jump = LTC.render(start: Timecode("01:00:10:00", rate: .fps30)!, frameCount: 60, sampleRate: sr)
        let gap = [Float](repeating: 0, count: 9_600)  // six frames of nothing
        let resume = LTC.render(start: Timecode("01:00:12:06", rate: .fps30)!, frameCount: 60, sampleRate: sr)
        let a = LTCAnalyzer.analyze(a1 + jump + gap + resume, sampleRate: sr)
        XCTAssertEqual(a.jumps.count, 1, "\(a.jumps)")
        XCTAssertEqual(a.jumps.first?.found.description, "01:00:10:00")
        XCTAssertEqual(a.dropouts.count, 1)
    }

    func testSilenceHasNoTimecode() {
        XCTAssertFalse(LTCAnalyzer.analyze([Float](repeating: 0, count: 48_000), sampleRate: 48_000).hasTimecode)
        let sine = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.5 }
        XCTAssertFalse(LTCAnalyzer.analyze(sine, sampleRate: 48_000).hasTimecode)
    }

    func testPicksTheChannelWithTimecode() {
        let start = Timecode("05:00:00:00", rate: .fps30)!
        let tc = LTC.render(start: start, frameCount: 40, sampleRate: 48_000)
        let music = (0..<tc.count).map { Float(sin(Double($0) * 0.01)) * 0.3 }
        let best = LTCAnalyzer.analyze(channels: [music, tc], sampleRate: 48_000)
        XCTAssertEqual(best?.channel, 1)
        XCTAssertEqual(best?.analysis.first, start)
    }

    func testWAVRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Timecode("06:00:00:00", rate: .fps29_97)!
        let tc = LTC.render(start: start, frameCount: 60, sampleRate: 48_000)
        for bits in [16, 24] {
            let url = dir.appendingPathComponent("tc\(bits).wav")
            try WAVFile.write(channels: [tc, tc.map { $0 * 0.5 }], sampleRate: 48_000, bitDepth: bits, to: url)
            let info = try WAVFile().info(of: url)
            XCTAssertEqual(info, AudioFileInfo(sampleRate: 48_000, channelCount: 2, frameCount: tc.count))
            let read = try WAVFile().readChannels(of: url)
            XCTAssertEqual(read.channels[1][100], tc[100] * 0.5, accuracy: 0.0002)
            XCTAssertEqual(LTCAnalyzer.analyze(read.channels[0], sampleRate: 48_000).first, start)
        }
    }
}
