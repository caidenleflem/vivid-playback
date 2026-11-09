import XCTest
@testable import PlaybackCore

/// The layout of a real tour sheet (Google Sheets export): title rows, a header with
/// "LTC start" next to a Yes/No "Timecode" column, songs with no LTC, intros sharing their
/// song's address, a cue row, and a totals line. Song names here are made up.
final class RealSheetTests: XCTestCase {
    static let csv = """
    EXAMPLE ARTIST · EXAMPLE TOUR · FALL 26 · SETLIST,,,,,,,,,,,,,,,,,,,stemmdigital
    "Setlist V1.7.7 · Show file EXAMPLE V1.4 · LTC 30 fps · Updated 20 Oct 2026",,,,,,,,,,,,,,,,,,,
    ,,,,,,,,,,,,,,,,,,,
    #,Part,Song,Type,BPM,Tempo moves,Time sig,Key,Tuning (Hz),LTC start,Timecode,LTC ref,Ref,Ref link,Ref date,Length,Show calls / stage cues,Notes,,
    1,Interstitial,INTERSTITIAL 1,interstitial,75,,4/4,,,04:00:00:00,Yes,,Yes,LA show,19 Oct 2026,1:37,,,,
    2,Act 1,OPENER & FRIENDS,song,149,,4/4,Gb Min,445.6,00:00:00:00,Yes,,Yes,LA show,19 Oct 2026,1:12,,LTC ref is from an earlier show file,,
    3,Act 1,SUMMER,song,92,84.5–92.0,4/4,Eb Min,443,00:10:00:00,Yes,,Yes,LA show,19 Oct 2026,2:42,HOLD CENTRE,,,
    7,Act 1,COMEBACK INTRO,intro,92,92.0–162.0,4/4,F# Min,444,00:20:00:00,Yes,,Yes,LA show,19 Oct 2026,0:35,,,,
    8,Act 1,COMEBACK,song,162,78.0–162.0,4/4,F# Min,444,00:20:00:00,Yes,,Yes,LA show,19 Oct 2026,2:49,,,,
    24,Act 3,SLOW ONE | LOOPED VERSION,song,80,,6/8,C Maj,440,,No,,Yes,LA show,19 Oct 2026,6:07,,"Looped version · no timecode",,
    31,Interstitial,PRE ENCORE,interstitial,128.48,128.5–142.6,4/4,,,,No,,Yes,LA show,19 Oct 2026,2:59,,,,
    42,CRAIG CUE,NOT A SONG | NOT A SONG,,,,,,,04:30:00:00,,,,,,,,,,
    43,Encore,LAST ONE,song,93,,4/4,E Min,440,07:00:00:00,Yes,,Yes,London 1 show,1 Nov 2026,3:45,,"In show file since EU V5.3 · new LTC address",,
    ,,Main show 100 min (setlist V1.7.7) · 27 songs · 6 spares · 2 to add,,,,,,,,,,,,,,,,,
    """

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testReadsTheTourSheet() {
        let sheet = OffsetSheetParser.read(text: Self.csv)
        XCTAssertEqual(sheet.mapping.headerRow, 3)
        XCTAssertEqual(sheet.mapping.columns[.number], 0)
        XCTAssertEqual(sheet.mapping.columns[.title], 2)
        XCTAssertEqual(sheet.mapping.columns[.start], 9, "LTC start, not the Yes/No Timecode column")
        XCTAssertEqual(sheet.mapping.columns[.length], 15)
        XCTAssertEqual(sheet.rows.count, 9, "the totals line isn't a song")
        XCTAssertEqual(sheet.problems.count, 2)
        XCTAssertTrue(sheet.problems[0].contains("SLOW ONE"))
    }

    func testImportsWithNoAudioAndKeepsNoTimecodeSongs() throws {
        let url = dir.appendingPathComponent("Example Tour V1.2 - Songs.csv")
        try Self.csv.write(to: url, atomically: true, encoding: .utf8)
        let report = try ShowImporter().importFolder(dir, sheet: url, scanAudio: false, name: "Example Tour")
        XCTAssertEqual(report.show.songs.count, 9)
        let slow = try XCTUnwrap(report.show.songs.first { $0.title.hasPrefix("SLOW ONE") })
        XCTAssertFalse(slow.hasTimecode)
        XCTAssertEqual(slow.length ?? 0, 367, accuracy: 0.01)
        let kinds = report.issues.map(\.kind)
        XCTAssertFalse(report.issues.contains { $0.songID == slow.id && $0.kind == .missingTimecode })
        XCTAssertTrue(kinds.contains(.duplicateStart), "the intro and its song share 00:20:00:00, and that's said out loud")
        // Every song with a start can still send timecode (generated), and the no-timecode ones play silent timecode.
        let b = PlaybackBuffers.prepare(song: slow, sampleRate: 48_000, master: [[Float](repeating: 0, count: 100)], timecode: nil)
        XCTAssertFalse(b.timecodeGenerated)
        XCTAssertEqual(b.timecodeSample(frame: 50), 0)
    }

    func testPicksTheSheetWithTimecodeAmongOtherExports() throws {
        try Self.csv.write(to: dir.appendingPathComponent("Example Tour V1.2 - Songs.csv"), atomically: true, encoding: .utf8)
        try "Cue,Who,Note\n1,LX,Go\n2,Video,Standby\n".write(to: dir.appendingPathComponent("Example Tour V1.2 - Cue list.csv"), atomically: true, encoding: .utf8)
        try "Date,City\n1 Nov,London\n".write(to: dir.appendingPathComponent("Example Tour V1.2 - Setlist dates.csv"), atomically: true, encoding: .utf8)
        let report = try ShowImporter().importFolder(dir)
        XCTAssertEqual(report.sheetURL?.lastPathComponent, "Example Tour V1.2 - Songs.csv")
    }

    func testUnreadableStartIsNotTurnedIntoANoTimecodeSong() throws {
        let csv = "#,Title,LTC start\n1,Good,01:00:00:00\n2,Typo,1:00\n3,No LTC,\n"
        let url = dir.appendingPathComponent("s.csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        let report = try ShowImporter().importFolder(dir, sheet: url, scanAudio: false)
        XCTAssertEqual(report.show.songs.map(\.title), ["Good", "No LTC"])
        XCTAssertTrue(report.sheetProblems.contains { $0.contains("Typo") })
    }

    func testNoSheetWithStartsSaysWhichFilesWereTried() throws {
        try "Date,City\n1 Nov,London\n".write(to: dir.appendingPathComponent("dates.csv"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ShowImporter().importFolder(dir)) { error in
            XCTAssertEqual(error as? ImportError, .emptySheet("dates.csv"))
            XCTAssertTrue(String(describing: error).contains("dates.csv"))
        }
    }
}
