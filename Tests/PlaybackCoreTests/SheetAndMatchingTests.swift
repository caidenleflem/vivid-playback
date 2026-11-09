import XCTest
@testable import PlaybackCore

final class SheetTests: XCTestCase {
    func testCSVQuotesAndLineEndings() {
        let text = "\u{FEFF}Song #,Title,Notes\r\n1,\"Overture, Part 1\",\"He said \"\"go\"\"\"\r\n2,Golden Hour,\n"
        let rows = DelimitedText.parse(text)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["1", "Overture, Part 1", "He said \"go\""])
        XCTAssertEqual(rows[2], ["2", "Golden Hour", ""])
    }

    func testTabDetection() {
        let rows = DelimitedText.parse("No\tTitle\tTC Start\n3\tNight Drive, Live\t03:00:00:00\n")
        XCTAssertEqual(rows[1], ["3", "Night Drive, Live", "03:00:00:00"])
    }

    func testTypicalSheet() {
        let csv = """
        Example Tour 2027,,,,
        Song #,Title,TC Start,FPS,Length
        1,Overture,01:00:00:00,30,1:36
        2,Golden Hour,02:00:00:00,30,3:58
        ,,,,
        3,Night Drive,03:00:00:00,30,4:31.5
        """
        let sheet = OffsetSheetParser.read(text: csv)
        XCTAssertEqual(sheet.mapping.headerRow, 1)
        XCTAssertEqual(sheet.mapping.columns[.number], 0)
        XCTAssertEqual(sheet.mapping.columns[.title], 1)
        XCTAssertEqual(sheet.mapping.columns[.start], 2)
        XCTAssertEqual(sheet.mapping.columns[.rate], 3)
        XCTAssertEqual(sheet.mapping.columns[.length], 4)
        XCTAssertEqual(sheet.rows.map(\.title), ["Overture", "Golden Hour", "Night Drive"])
        XCTAssertEqual(sheet.rows[2].start?.description, "03:00:00:00")
        XCTAssertEqual(sheet.rows[2].length, 271.5)
        XCTAssertEqual(sheet.rows[0].number, 1)
        XCTAssertTrue(sheet.problems.isEmpty, "\(sheet.problems)")
    }

    func testOffsetColumnHoldingTimecodeIsTheStart() {
        let csv = """
        Song,Offset,Rate
        Overture,01:00:00:00,29.97 DF
        Afterglow,04:00:00;00,29.97 DF
        """
        let sheet = OffsetSheetParser.read(text: csv)
        XCTAssertEqual(sheet.mapping.columns[.title], 0)
        XCTAssertEqual(sheet.mapping.columns[.start], 1)
        XCTAssertEqual(sheet.rows[1].start?.description, "04:00:00;00")
        XCTAssertEqual(sheet.rows[1].start?.rate, .fps29_97DF)
    }

    func testOffsetColumnHoldingSecondsIsAFileOffset() {
        let csv = """
        Title,TC In,Offset
        Overture,01:00:00:00,2
        Night Drive,03:00:00:00,2.5
        """
        let sheet = OffsetSheetParser.read(text: csv)
        XCTAssertEqual(sheet.mapping.columns[.start], 1)
        XCTAssertEqual(sheet.mapping.columns[.fileOffset], 2)
        XCTAssertEqual(sheet.rows[1].fileOffset, 2.5)
    }

    func testNoHeader() {
        let csv = """
        1,Overture,01:00:00:00,01 Overture.wav,01 Overture LTC.wav
        2,Golden Hour,02:00:00:00,02 Golden Hour.wav,02 Golden Hour LTC.wav
        """
        let sheet = OffsetSheetParser.read(text: csv)
        XCTAssertNil(sheet.mapping.headerRow)
        XCTAssertEqual(sheet.mapping.columns[.number], 0)
        XCTAssertEqual(sheet.mapping.columns[.title], 1)
        XCTAssertEqual(sheet.mapping.columns[.start], 2)
        XCTAssertEqual(sheet.mapping.columns[.masterFile], 3)
        XCTAssertEqual(sheet.mapping.columns[.timecodeFile], 4)
        XCTAssertEqual(sheet.rows[1].timecodeFile, "02 Golden Hour LTC.wav")
    }

    func testBadRowsAreReportedNotGuessed() {
        let csv = """
        Title,Start,FPS
        Overture,01:00:00:00,30
        Golden Hour,2:00,30
        Low Light,,30
        Velvet,10:00:00:00,60
        """
        let sheet = OffsetSheetParser.read(text: csv)
        XCTAssertNil(sheet.rows[1].start)
        XCTAssertEqual(sheet.problems.count, 3, "\(sheet.problems)")
        XCTAssertTrue(sheet.problems[0].contains("Golden Hour"))
        XCTAssertEqual(sheet.rows[3].start?.rate, .fps30, "unreadable rate falls back to the show's rate")
    }
}

final class MatchingTests: XCTestCase {
    let folder = URL(fileURLWithPath: "/show")
    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    func row(_ i: Int, _ n: Int?, _ title: String, master: String? = nil, tc: String? = nil) -> SheetRow {
        SheetRow(rowIndex: i, number: n, title: title, start: Timecode(frameCount: 0, rate: .fps30), end: nil, length: nil, rate: nil,
                 fileOffset: nil, masterFile: master, timecodeFile: tc, notes: nil)
    }

    func testRoles() {
        XCTAssertEqual(FileMatcher.role(forFileName: "03 Night Drive LTC.wav"), .timecode)
        XCTAssertEqual(FileMatcher.role(forFileName: "03_NightDrive_TC.wav"), .timecode)
        XCTAssertEqual(FileMatcher.role(forFileName: "Night Drive (timecode).aif"), .timecode)
        XCTAssertEqual(FileMatcher.role(forFileName: "03 Night Drive - Master.wav"), .master)
        XCTAssertEqual(FileMatcher.role(forFileName: "03 Night Drive Click.wav"), .other)
        XCTAssertEqual(FileMatcher.role(forFileName: "Tactics.wav"), .master, "tc inside a word isn't a token")
        XCTAssertEqual(FileMatcher.songNumber(inFileName: "Tour 2027 - 03 - Night Drive.wav"), 3)
        XCTAssertEqual(FileMatcher.songNumber(inFileName: "Song3_LTC.wav"), 3)
    }

    func testMatchByNumberAndTitle() {
        let files = ["01 Overture.wav", "01 Overture LTC.wav", "Golden Hour - Master.wav", "Golden Hour - LTC.wav",
                     "03 Night Drive.wav", "03_NightDrive_TC.wav", "Click.wav"].map(url)
        let rows = [row(0, 1, "Overture"), row(1, 2, "Golden Hour"), row(2, 3, "Night Drive")]
        let r = FileMatcher.match(rows: rows, files: files)
        XCTAssertEqual(r.matches[0]?.master?.lastPathComponent, "01 Overture.wav")
        XCTAssertEqual(r.matches[0]?.timecode?.lastPathComponent, "01 Overture LTC.wav")
        XCTAssertEqual(r.matches[1]?.master?.lastPathComponent, "Golden Hour - Master.wav")
        XCTAssertEqual(r.matches[1]?.timecode?.lastPathComponent, "Golden Hour - LTC.wav")
        XCTAssertEqual(r.matches[2]?.timecode?.lastPathComponent, "03_NightDrive_TC.wav")
        XCTAssertEqual(r.unmatched.map(\.lastPathComponent), ["Click.wav"])
        XCTAssertTrue(r.ambiguities.isEmpty)
    }

    func testNumberWithDisagreeingTitleIsNotMatched() {
        let files = ["03 Afterglow.wav"].map(url)
        let r = FileMatcher.match(rows: [row(0, 3, "Night Drive")], files: files)
        XCTAssertNil(r.matches[0]?.master)
    }

    func testSheetNamedFilesWin() {
        let files = ["a.wav", "b.wav", "Night Drive.wav"].map(url)
        let r = FileMatcher.match(rows: [row(0, nil, "Night Drive", master: "b.wav", tc: "a")], files: files)
        XCTAssertEqual(r.matches[0]?.master?.lastPathComponent, "b.wav")
        XCTAssertEqual(r.matches[0]?.timecode?.lastPathComponent, "a.wav")
    }

    func testAmbiguityIsReported() {
        let files = ["Night Drive v1.wav", "Night Drive v2.wav"].map(url)
        let r = FileMatcher.match(rows: [row(0, nil, "Night Drive")], files: files)
        XCTAssertNil(r.matches[0]?.master)
        XCTAssertEqual(r.ambiguities.count, 1)
    }
}
