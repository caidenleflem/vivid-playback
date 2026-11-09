import XCTest
@testable import PlaybackCore

/// The clock and the output must follow the timecode file, never the sheet's arithmetic.
final class TimecodeSourceTests: XCTestCase {
    let sr = 48_000.0

    func testTrackReadsTheFileNotTheSheet() throws {
        // A file with 1 s of silence, then LTC from 00:59:58:00 (two seconds of pre-roll).
        let silence = [Float](repeating: 0, count: Int(sr))
        let ltc = LTC.render(start: Timecode("00:59:58:00", rate: .fps30)!, frameCount: 150, sampleRate: sr)
        let track = try XCTUnwrap(LTCTrack(samples: silence + ltc, sampleRate: sr))
        XCTAssertEqual(track.rate, .fps30)
        XCTAssertNil(track.timecode(atSample: 1000), "no timecode during the silence")
        XCTAssertEqual(track.timecode(atSample: Int(sr) + 10)?.description, "00:59:58:00")
        XCTAssertEqual(track.timecode(atSample: Int(sr * 3) + 10)?.description, "01:00:00:00")
        XCTAssertEqual(track.timecode(atSample: Int(sr * 3.5))?.description, "01:00:00:15")
        XCTAssertNil(track.timecode(atSample: Int(sr * 9)), "no timecode after the file's LTC ends")
    }

    func testAFileIsPlayedAsIsWithItsOwnTrack() {
        let song = Song(title: "July", start: Timecode("00:10:00:00", rate: .fps30)!)
        // The file says 00:10:05:00, not the sheet's 00:10:00:00.
        let ltc = LTC.render(start: Timecode("00:10:05:00", rate: .fps30)!, frameCount: 60, sampleRate: sr)
        let b = PlaybackBuffers.prepare(song: song, sampleRate: sr, master: [[Float](repeating: 0, count: ltc.count)],
                                        timecode: ltc, timecodeFile: "JULY LTC.wav")
        XCTAssertEqual(b.source, .file("JULY LTC.wav"))
        XCTAssertFalse(b.timecodeGenerated)
        XCTAssertEqual(b.timecodeSample(frame: 500), ltc[500], "the file's own samples go out")
        XCTAssertEqual(b.ltc?.timecode(atSample: 10)?.description, "00:10:05:00", "the clock follows the file")
    }

    func testAnUnreadableFileSendsNothingRatherThanASubstitute() {
        var song = Song(title: "July", start: Timecode("00:10:00:00", rate: .fps30)!)
        song.timecodePath = "JULY LTC.wav"
        let b = PlaybackBuffers.prepare(song: song, sampleRate: sr, master: [[Float](repeating: 0.2, count: 1000)],
                                        timecode: nil, timecodeFile: "JULY LTC.wav", timecodeFileProblem: "Couldn't read JULY LTC.wav.")
        XCTAssertEqual(b.source, .unreadable("Couldn't read JULY LTC.wav."))
        XCTAssertEqual(b.timecodeSample(frame: 500), 0)
        XCTAssertNil(b.ltc)
    }

    func testFilesAreToldApartByListening() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roles-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ltc = LTC.render(start: Timecode("00:10:00:00", rate: .fps30)!, frameCount: 90, sampleRate: sr)
        let music = (0..<ltc.count).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        let oddlyNamed = dir.appendingPathComponent("03 JULY REF.wav")
        try WAVFile.write(channels: [ltc], sampleRate: 48_000, bitDepth: 16, to: oddlyNamed)
        let master = dir.appendingPathComponent("03 JULY.wav")
        try WAVFile.write(channels: [music, music], sampleRate: 48_000, bitDepth: 16, to: master)
        let lateTC = dir.appendingPathComponent("03 JULY LTC.wav")
        try WAVFile.write(channels: [[Float](repeating: 0, count: 4800)], sampleRate: 48_000, bitDepth: 16, to: lateTC)

        XCTAssertEqual(ShowImporter.detectRole(oddlyNamed, reader: WAVFile()), .timecode, "LTC inside wins over the name")
        XCTAssertEqual(ShowImporter.detectRole(master, reader: WAVFile()), .master)
        XCTAssertEqual(ShowImporter.detectRole(lateTC, reader: WAVFile()), .timecode, "named timecode, no LTC heard: the name stands")

        var show = Show(name: "x", mediaFolder: dir.path, songs: [Song(number: 3, title: "JULY", start: Timecode("00:10:00:00", rate: .fps30)!)])
        let r = ShowImporter.attach([oddlyNamed, master], to: &show, reader: WAVFile())
        XCTAssertEqual(show.songs[0].timecodePath, "03 JULY REF.wav")
        XCTAssertEqual(show.songs[0].masterPath, "03 JULY.wav")
        XCTAssertEqual(r.attached.count, 2)
    }
}
