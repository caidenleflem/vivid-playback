import XCTest
@testable import PlaybackCore

final class TimecodeTests: XCTestCase {
    func testRoundTripEveryRate() {
        for rate in FrameRate.allCases {
            for count in stride(from: 0, to: rate.framesPerDay, by: 7919) {
                let tc = Timecode(frameCount: count, rate: rate)
                let c = tc.components
                let back = Timecode(hours: c.hours, minutes: c.minutes, seconds: c.seconds, frames: c.frames, rate: rate)
                XCTAssertEqual(back?.frameCount, count, "\(rate) \(tc)")
                XCTAssertEqual(Timecode(tc.description, rate: rate)?.frameCount, count, "\(rate) \(tc)")
            }
        }
    }

    func testDropFrameBoundaries() {
        let r = FrameRate.fps29_97DF
        let a = Timecode("00:00:59;29", rate: r)!
        XCTAssertEqual(a.adding(frames: 1).description, "00:01:00;02")
        let b = Timecode("00:09:59;29", rate: r)!
        XCTAssertEqual(b.adding(frames: 1).description, "00:10:00;00")
        XCTAssertNil(Timecode("00:01:00;00", rate: r), "dropped label")
        XCTAssertNil(Timecode("00:01:00;01", rate: r), "dropped label")
        XCTAssertNotNil(Timecode("00:10:00;00", rate: r))
        XCTAssertEqual(Timecode("01:00:00;00", rate: r)!.frameCount, 107_892)
        XCTAssertEqual(Timecode("01:00:00;00", rate: r)!.seconds, 3600, accuracy: 0.004)
        XCTAssertEqual(r.framesPerDay, 2_589_408)
    }

    func testNonDropRealTime() {
        // 29.97 non-drop runs slow: one labelled hour is 3603.6 real seconds.
        XCTAssertEqual(Timecode("01:00:00:00", rate: .fps29_97)!.seconds, 3603.6, accuracy: 0.001)
        XCTAssertEqual(Timecode("01:00:00:00", rate: .fps30)!.seconds, 3600, accuracy: 0.0001)
        XCTAssertEqual(Timecode("00:00:01:12", rate: .fps25)!.frameCount, 37)
    }

    func testParsingAndValidation() {
        XCTAssertNil(Timecode("01:00:00:30", rate: .fps30))
        XCTAssertNil(Timecode("01:00:00:25", rate: .fps25))
        XCTAssertNil(Timecode("24:00:00:00", rate: .fps30))
        XCTAssertNil(Timecode("1:00", rate: .fps30))
        XCTAssertNil(Timecode("ab:00:00:00", rate: .fps30))
        XCTAssertEqual(Timecode("03:00:00", rate: .fps30)?.description, "03:00:00:00")
        XCTAssertEqual(Timecode("03.00.10.05", rate: .fps30)?.description, "03:00:10:05")
        XCTAssertEqual(Timecode("00:00:00;05", rate: .fps29_97DF)?.description, "00:00:00;05")
    }

    func testWrapAndDistance() {
        let late = Timecode("23:59:59:29", rate: .fps30)!
        XCTAssertEqual(late.adding(frames: 1).description, "00:00:00:00")
        XCTAssertEqual(Timecode("00:00:00:01", rate: .fps30)!.frames(since: late), 2)
        XCTAssertEqual(Timecode("03:00:00:00", rate: .fps30)!.frames(since: Timecode("03:00:01:00", rate: .fps30)!), -30)
    }

    func testSecondsInit() {
        XCTAssertEqual(Timecode(seconds: 1.0, rate: .fps30).description, "00:00:01:00")
        XCTAssertEqual(Timecode(seconds: 0.999, rate: .fps30).description, "00:00:00:29")
    }

    func testRateParsing() {
        XCTAssertEqual(FrameRate.parse("30"), .fps30)
        XCTAssertEqual(FrameRate.parse("30 fps"), .fps30)
        XCTAssertEqual(FrameRate.parse("29.97 DF"), .fps29_97DF)
        XCTAssertEqual(FrameRate.parse("29.97df"), .fps29_97DF)
        XCTAssertEqual(FrameRate.parse("29.97 NDF"), .fps29_97)
        XCTAssertEqual(FrameRate.parse("2997"), .fps29_97)
        XCTAssertEqual(FrameRate.parse("30 drop"), .fps29_97DF)
        XCTAssertEqual(FrameRate.parse("23.98"), .fps23_976)
        XCTAssertEqual(FrameRate.parse("25fps"), .fps25)
        XCTAssertEqual(FrameRate.parse("24"), .fps24)
        XCTAssertNil(FrameRate.parse("60"))
        XCTAssertNil(FrameRate.parse(""))
    }

    func testCodable() throws {
        let tc = Timecode("04:00:00;02", rate: .fps29_97DF)!
        let data = try JSONEncoder().encode(tc)
        XCTAssertEqual(try JSONDecoder().decode(Timecode.self, from: data), tc)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("04:00:00;02"))
    }

    func testDurations() {
        XCTAssertEqual(TimeFormat.parseDuration("4:31"), 271)
        XCTAssertEqual(TimeFormat.parseDuration("04:31.5"), 271.5)
        XCTAssertEqual(TimeFormat.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(TimeFormat.parseDuration("271.5 s"), 271.5)
        XCTAssertNil(TimeFormat.parseDuration("soon"))
        XCTAssertEqual(TimeFormat.clock(271.9), "4:31")
        XCTAssertEqual(TimeFormat.clock(3723), "1:02:03")
    }

    func testPlaybackMath() {
        let song = Song(title: "Night Drive", start: Timecode("03:00:00:00", rate: .fps30)!, fileOffset: 2)
        XCTAssertEqual(PlaybackMath.fileTime(for: song.start, in: song), 2)
        XCTAssertEqual(PlaybackMath.fileTime(for: Timecode("03:00:01:15", rate: .fps30)!, in: song), 3.5, accuracy: 1e-9)
        XCTAssertEqual(PlaybackMath.timecode(atFileTime: 3.5, in: song).description, "03:00:01:15")
        XCTAssertEqual(PlaybackMath.timecode(atFileTime: 1, in: song).description, "02:59:59:00")
        XCTAssertEqual(PlaybackMath.sampleFrame(for: song.start, in: song, sampleRate: 48_000), 96_000)
    }
}
