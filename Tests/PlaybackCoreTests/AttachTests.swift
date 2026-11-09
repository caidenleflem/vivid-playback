import XCTest
@testable import PlaybackCore

final class AttachTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Audio"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func show() throws -> Show {
        let csv = "#,Song,LTC start,Length\n1,Overture,01:00:00:00,0:04\n2,Golden Hour,02:00:00:00,0:04\n3,Pre Encore,,0:04\n"
        let url = dir.appendingPathComponent("Songs.csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return try ShowImporter().importFolder(dir, sheet: url, scanAudio: false).show
    }

    func ltc(_ start: String, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent("Audio/\(name)")
        try WAVFile.write(channels: [LTC.render(start: Timecode(start, rate: .fps30)!, frameCount: 90, sampleRate: 48_000)],
                          sampleRate: 48_000, bitDepth: 16, to: url)
        return url
    }

    func tone(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent("Audio/\(name)")
        try WAVFile.write(channels: [[Float](repeating: 0.1, count: 4800)], sampleRate: 48_000, bitDepth: 16, to: url)
        return url
    }

    func testAddingAFolderFillsOnlyWhatsMissing() throws {
        var s = try show()
        _ = try tone("01 Overture.wav")
        _ = try ltc("01:00:00:00", "01 Overture LTC.wav")
        _ = try tone("02 Golden Hour.wav")
        _ = try tone("Spare Click.wav")
        let r = ShowImporter.attach(ShowImporter.expand([dir.appendingPathComponent("Audio")]), to: &s)
        XCTAssertEqual(r.attached, ["Overture · master", "Overture · timecode", "Golden Hour · master"])
        XCTAssertEqual(r.unused, ["Spare Click.wav"])
        XCTAssertEqual(s.songs[0].masterPath, "Audio/01 Overture.wav")
        XCTAssertNil(s.songs[1].timecodePath)

        // A second pass never replaces a file a song already has.
        _ = try tone("01 Overture v2.wav")
        let again = ShowImporter.attach([dir.appendingPathComponent("Audio/01 Overture v2.wav")], to: &s)
        XCTAssertTrue(again.attached.isEmpty)
        XCTAssertEqual(s.songs[0].masterPath, "Audio/01 Overture.wav")
    }

    func testTimecodeFileGivesANoTimecodeSongItsStart() throws {
        var s = try show()
        let pre = try XCTUnwrap(s.songs.first { $0.title == "Pre Encore" })
        XCTAssertFalse(pre.hasTimecode)
        let url = try ltc("04:40:00:00", "Pre Encore TC.wav")
        let updated = try ShowImporter.assign(url, role: .timecode, songID: pre.id, in: &s, reader: WAVFile())
        XCTAssertEqual(updated?.hasTimecode, true)
        XCTAssertEqual(updated?.start.description, "04:40:00:00")
        XCTAssertEqual(updated?.timecodePath, "Audio/Pre Encore TC.wav")

        // A file with no timecode in it can't give a no-timecode song a start.
        var fresh = try show()
        let silent = try tone("silence.wav")
        XCTAssertThrowsError(try ShowImporter.assign(silent, role: .timecode, songID: fresh.songs[2].id, in: &fresh, reader: WAVFile())) {
            XCTAssertEqual($0 as? AttachError, .noTimecodeInFile("silence.wav"))
        }
        XCTAssertFalse(fresh.songs[2].hasTimecode, "nothing changes when it fails")
    }

    func testAssignReplacesAndRemoveClears() throws {
        var s = try show()
        let id = s.songs[1].id
        let a = try tone("anything.wav")
        try ShowImporter.assign(a, role: .master, songID: id, in: &s, reader: WAVFile())
        XCTAssertEqual(s.songs[1].masterPath, "Audio/anything.wav")
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString.prefix(4)).wav")
        try WAVFile.write(channels: [[0, 0]], sampleRate: 48_000, to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try ShowImporter.assign(elsewhere, role: .master, songID: id, in: &s, reader: WAVFile())
        XCTAssertEqual(s.songs[1].masterPath, elsewhere.standardizedFileURL.path, "files outside the show folder keep their full path")
        XCTAssertEqual(s.url(forMediaPath: s.songs[1].masterPath)?.standardizedFileURL, elsewhere.standardizedFileURL)
        ShowImporter.remove(.master, songID: id, in: &s)
        XCTAssertNil(s.songs[1].masterPath)
    }
}
