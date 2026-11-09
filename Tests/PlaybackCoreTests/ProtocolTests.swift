import XCTest
@testable import PlaybackCore

final class ProtocolTests: XCTestCase {
    func testMTCRoundTrip() {
        for rate in [FrameRate.fps24, .fps25, .fps29_97DF, .fps30] {
            let tc = rate.isDropFrame ? Timecode("03:10:20;15", rate: rate)! : Timecode("03:10:20:15", rate: rate)!
            var reader = MTCReader()
            // Full frame.
            XCTAssertEqual(reader.receive(MTC.fullFrame(tc)), tc)
            // Eight quarter frames carry tc; they complete two frames later.
            var out: Timecode?
            for piece in 0..<8 { out = reader.receive(MTC.quarterFrame(piece, of: tc)) ?? out }
            XCTAssertEqual(out, tc.adding(frames: 2), "\(rate)")
            XCTAssertEqual(reader.rate, rate)
        }
    }

    func testMTCQuarterFramesOutOfOrderAreIgnored() {
        let tc = Timecode("01:00:00:00", rate: .fps30)!
        var reader = MTCReader()
        XCTAssertNil(reader.receive(MTC.quarterFrame(3, of: tc)))
        for piece in [0, 1, 2, 5] { XCTAssertNil(reader.receive(MTC.quarterFrame(piece, of: tc))) }
    }

    func testMTCBytes() {
        XCTAssertEqual(MTC.fullFrame(Timecode("01:02:03:04", rate: .fps30)!), [0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x61, 2, 3, 4, 0xF7])
        XCTAssertEqual(MTC.quarterFrame(7, of: Timecode("17:00:00:00", rate: .fps25)!), [0xF1, 0x73])
    }

    func testMMC() {
        XCTAssertEqual(MMCCommand.parse([0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7]), .play)
        XCTAssertEqual(MMCCommand.parse([0xF0, 0x7F, 0x00, 0x06, 0x01, 0xF7]), .stop)
        XCTAssertEqual(MMCCommand.parse([0xF0, 0x7F, 0x7F, 0x06, 0x44, 0x06, 0x01, 0x61, 2, 3, 4, 0, 0xF7]),
                       .locate(hours: 1, minutes: 2, seconds: 3, frames: 4))
        XCTAssertNil(MMCCommand.parse([0xF0, 0x7E, 0x7F, 0x06, 0x02, 0xF7]))
    }

    func testArtNet() {
        let tc = Timecode("04:30:12:29", rate: .fps30)!
        let p = ArtNetTimecode.packet(tc)
        XCTAssertEqual(p.count, 19)
        XCTAssertEqual(Array(p[8...9]), [0x00, 0x97])
        XCTAssertEqual(ArtNetTimecode.parse(p), tc)
        XCTAssertEqual(ArtNetTimecode.parse(ArtNetTimecode.packet(Timecode("00:10:00;02", rate: .fps29_97DF)!))?.description, "00:10:00;02")
        XCTAssertNil(ArtNetTimecode.parse(Array("Art-Net".utf8) + [0, 0x00, 0x50]))
    }

    func testOSC() {
        let m = OSCMessage("/vivid/song", [.int(12)])
        XCTAssertEqual(OSCMessage.parse(m.encoded()), [m])
        let mixed = OSCMessage("/vivid/locate", [.string("01:00:00:00"), .float(1.5)])
        XCTAssertEqual(OSCMessage.parse(mixed.encoded()), [mixed])
        // A bundle with two messages.
        let a = OSCMessage("/vivid/stop").encoded(), b = OSCMessage("/vivid/go", [.int(1)]).encoded()
        var bundle = Array("#bundle".utf8) + [0] + [UInt8](repeating: 0, count: 8)
        for e in [a, b] { bundle += withUnsafeBytes(of: UInt32(e.count).bigEndian, Array.init) + e }
        XCTAssertEqual(OSCMessage.parse(bundle).map(\.address), ["/vivid/stop", "/vivid/go"])
        XCTAssertEqual(OSCMessage.parse([1, 2, 3]), [])
    }

    func testRemoteCommands() {
        XCTAssertEqual(RemoteCommand.from(OSCMessage("/vivid/go")), .play)
        XCTAssertEqual(RemoteCommand.from(OSCMessage("/Vivid/GO", [.float(1)])), .play)
        XCTAssertNil(RemoteCommand.from(OSCMessage("/vivid/go", [.int(0)])), "button release")
        XCTAssertEqual(RemoteCommand.from(OSCMessage("/vivid/song", [.int(12)])), .song(number: 12))
        XCTAssertEqual(RemoteCommand.from(OSCMessage("/vivid/song", [.string("JULY")])), .songTitle("JULY"))
        XCTAssertEqual(RemoteCommand.from(OSCMessage("/vivid/locate", [.string("01:00:00:00")])), .locate("01:00:00:00"))
        XCTAssertEqual(RemoteCommand.from(OSCMessage("/vivid/stopafter", [.int(0)])), .stopAfterEach(false))
        XCTAssertNil(RemoteCommand.from(OSCMessage("/other/go")))
    }
}

final class ChaseTests: XCTestCase {
    func testStreamingDecoderMatchesTheBatchDecoder() {
        let sr = 48_000.0
        for rate in [FrameRate.fps24, .fps25, .fps29_97DF, .fps30] {
            let start = rate.isDropFrame ? Timecode("01:00:59;20", rate: rate)! : Timecode("01:00:59:20", rate: rate)!
            let ltc = [Float](repeating: 0, count: 777) + LTC.render(start: start, frameCount: 60, sampleRate: sr).map { $0 * 0.3 }
            let decoder = LTCStreamDecoder(sampleRate: sr)
            var frames: [LTCFrame] = []
            var i = 0
            var block = 37
            while i < ltc.count {   // odd, changing block sizes, like an audio input
                let n = min(block, ltc.count - i)
                frames += decoder.process(Array(ltc[i..<i + n]))
                i += n
                block = block == 37 ? 512 : (block == 512 ? 129 : 37)
            }
            XCTAssertGreaterThanOrEqual(frames.count, 58, "\(rate)")
            let codes = frames.compactMap { $0.timecode(rate: rate) }
            for (a, b) in zip(codes, codes.dropFirst()) { XCTAssertEqual(b, a.adding(frames: 1), "\(rate)") }
            // A live stream finishes a frame when the next one starts, so the very last may wait.
            XCTAssertTrue([start, start.adding(frames: 1)].contains(codes.first!), "\(rate)")
            XCTAssertTrue([start.adding(frames: 58), start.adding(frames: 59)].contains(codes.last!), "\(rate)")
        }
    }

    func songs() -> [Song] {
        [Song(title: "July", start: Timecode("00:10:00:00", rate: .fps30)!, fileOffset: 2, length: 162),
         Song(title: "Bleed", start: Timecode("00:40:00:00", rate: .fps30)!, length: 258)]
    }

    func testFindsTheSongAndPlaysOnlyOnceTimecodeRuns() {
        var chase = ChaseEngine()
        let list = songs()
        let tc = Timecode("00:40:01:00", rate: .fps30)!
        // A single frame (a locate, a parked console): cue, don't play.
        XCTAssertEqual(chase.receive(tc, at: 0, songs: list, currentSongID: nil, playhead: 0, playing: false),
                       [.cue(list[1].id, at: 1)])
        // Parked or scrubbing: the playhead follows, without playing.
        XCTAssertEqual(chase.receive(tc.adding(frames: 1), at: 0.033, songs: list, currentSongID: list[1].id, playhead: 1, playing: false),
                       [.locate(1 + 1.0 / 30)])
        // Counting up: play.
        let acts = chase.receive(tc.adding(frames: 2), at: 0.066, songs: list, currentSongID: list[1].id, playhead: 1, playing: false)
        XCTAssertEqual(acts.last, .play)
        XCTAssertTrue(chase.isRunning)
    }

    func testCorrectsDriftAndStopsWhenTimecodeStops() {
        var chase = ChaseEngine()
        let list = songs()
        var t = 0.0
        var tc = Timecode("00:10:00:00", rate: .fps30)!
        for _ in 0..<3 { _ = chase.receive(tc, at: t, songs: list, currentSongID: list[0].id, playhead: 0, playing: true); tc = tc.adding(frames: 1); t += 1.0 / 30 }
        // In step: nothing to do.
        XCTAssertEqual(chase.receive(tc, at: t, songs: list, currentSongID: list[0].id, playhead: 0.1, playing: true), [])
        // Drifted by a quarter second: relocate.
        tc = tc.adding(frames: 1); t += 1.0 / 30
        let drift = chase.receive(tc, at: t, songs: list, currentSongID: list[0].id, playhead: 0.4, playing: true)
        XCTAssertEqual(drift, [.locate(Double(4) / 30)])
        // Timecode stops: stop after the dropout time, once.
        XCTAssertEqual(chase.tick(at: t + 0.2, playing: true), [])
        XCTAssertEqual(chase.tick(at: t + 0.5, playing: true), [.stop])
        XCTAssertEqual(chase.tick(at: t + 0.9, playing: false), [])
    }

    func testPreRollAndOutsideEverySong() {
        let list = songs()
        XCTAssertEqual(ChaseEngine.locate(Timecode("00:09:59:00", rate: .fps30)!, in: list)?.seconds, -1, "inside July's 2 s pre-roll")
        XCTAssertNil(ChaseEngine.locate(Timecode("00:09:57:00", rate: .fps30)!, in: list))
        XCTAssertNil(ChaseEngine.locate(Timecode("02:00:00:00", rate: .fps30)!, in: list))
    }

    func testMeters() {
        let a = UnsafeMutablePointer<Float>.allocate(capacity: 4); defer { a.deallocate() }
        a.update(from: [0.1, -0.7, 0.2, 0.0], count: 4)
        let outs: [UnsafeMutablePointer<Float>?] = [a, nil]
        let peaks = UnsafeMutablePointer<Float>.allocate(capacity: 2); defer { peaks.deallocate() }
        peaks.initialize(repeating: 0, count: 2)
        outs.withUnsafeBufferPointer { Mixer.peaks($0, frames: 4, into: peaks, count: 2) }
        XCTAssertEqual(peaks[0], 0.7, accuracy: 1e-6)
        XCTAssertEqual(peaks[1], 0)
    }
}
