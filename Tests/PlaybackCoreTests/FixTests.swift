import XCTest
@testable import PlaybackCore

final class FixTests: XCTestCase {
    let sr = 48_000.0

    /// A timecode file with `preroll` seconds of LTC before `fileStartTC`'s song... built so its
    /// LTC at sample 0 reads `atZero`.
    func report(atZero: String, seconds: Double = 6, rate: FrameRate = .fps30) -> SongFileReport {
        let ltc = LTC.render(start: Timecode(atZero, rate: rate)!, frameCount: Int(seconds * rate.framesPerSecond), sampleRate: sr)
        let info = AudioFileInfo(sampleRate: sr, channelCount: 1, frameCount: ltc.count)
        return SongFileReport(master: info, timecode: info, analysis: LTCAnalyzer.analyze(ltc, sampleRate: sr))
    }

    func song(_ start: String, offset: Double = 0, rate: FrameRate = .fps30) -> Song {
        Song(title: "July", start: Timecode(start, rate: rate)!, fileOffset: offset, masterPath: "m.wav", timecodePath: "t.wav")
    }

    func testStartMismatchOffersBothFixesAndEachClearsIt() throws {
        // The file's LTC starts at 00:09:58:00: the sheet's 00:10:00:00 is 2 s in.
        let files = report(atZero: "00:09:58:00")
        let s = song("00:10:00:00")
        let issue = try XCTUnwrap(ShowValidator.validate(song: s, files: files).first { $0.kind == .startMismatch })
        XCTAssertEqual(issue.fixes.first, .useFileStart(Timecode("00:09:58:00", rate: .fps30)!))
        guard case .alignToSheet(let offset)? = issue.fixes.dropFirst().first else { return XCTFail("no align fix: \(issue.fixes)") }
        XCTAssertEqual(offset, 2, accuracy: 0.002)

        // Fix 1: use the file's timecode.
        var show = Show(name: "x", songs: [s])
        let before = ShowFixer.apply(issue.fixes[0], songID: s.id, to: &show)
        XCTAssertEqual(before, s)
        XCTAssertEqual(show.songs[0].start.description, "00:09:58:00")
        XCTAssertFalse(ShowValidator.validate(song: show.songs[0], files: files).contains { $0.kind == .startMismatch })
        ShowFixer.undo(s, in: &show)
        XCTAssertEqual(show.songs[0], s, "undo puts it back")

        // Fix 2: keep the sheet's start, begin 2 s into the file.
        ShowFixer.apply(issue.fixes[1], songID: s.id, to: &show)
        XCTAssertEqual(show.songs[0].start, s.start)
        XCTAssertEqual(show.songs[0].fileOffset, 2, accuracy: 0.002)
        XCTAssertFalse(ShowValidator.validate(song: show.songs[0], files: files).contains { $0.kind == .startMismatch })
    }

    func testNoAlignFixWhenTheFileNeverReadsTheSheetStart() throws {
        let files = report(atZero: "04:00:00:00")          // six seconds of 04:00:00:00…
        let s = song("03:00:00:00")                         // …the sheet wants 03:00:00:00
        let issue = try XCTUnwrap(ShowValidator.validate(song: s, files: files).first { $0.kind == .startMismatch })
        XCTAssertEqual(issue.fixes, [.useFileStart(Timecode("04:00:00:00", rate: .fps30)!)])
    }

    func testMarkersMoveWithTheStart() throws {
        var s = song("00:10:00:00")
        s.markers = [Marker(time: Timecode("00:10:05:00", rate: .fps30)!, label: "Verse")]
        var show = Show(name: "x", songs: [s])
        ShowFixer.apply(.useFileStart(Timecode("00:09:58:00", rate: .fps30)!), songID: s.id, to: &show)
        XCTAssertEqual(show.songs[0].markers[0].time.description, "00:10:03:00", "still 5 s into the song")
    }

    func testRateFix() throws {
        let files = report(atZero: "00:10:00;00", rate: .fps29_97DF)
        let s = song("00:10:00:00")
        let issue = try XCTUnwrap(ShowValidator.validate(song: s, files: files).first { $0.kind == .rateMismatch })
        XCTAssertEqual(issue.fixes.first, .useFileRate(.fps29_97DF))
        var show = Show(name: "x", songs: [s])
        ShowFixer.apply(.useFileRate(.fps29_97DF), songID: s.id, to: &show)
        XCTAssertEqual(show.songs[0].start.description, "00:10:00;00")
        XCTAssertTrue(ShowValidator.validate(song: show.songs[0], files: files).filter { [.rateMismatch, .startMismatch].contains($0.kind) }.isEmpty)
    }

    func testOtherFindingsOfferTheRightActions() {
        var s = song("00:10:00:00")
        s.masterPath = nil
        s.timecodePath = nil
        let issues = ShowValidator.validate(song: s, files: SongFileReport())
        XCTAssertEqual(issues.first { $0.kind == .missingMaster }?.fixes, [.chooseMaster])
        XCTAssertEqual(issues.first { $0.kind == .missingTimecode }?.fixes, [.chooseTimecode])
        XCTAssertFalse(IssueFix.locate(seconds: 1).changesShow)
        XCTAssertTrue(IssueFix.alignToSheet(fileOffset: 1).changesShow)
    }
}
