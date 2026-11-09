import XCTest
@testable import PlaybackCore

final class DismissTests: XCTestCase {
    func issue(_ severity: ShowIssue.Severity, _ message: String, song: UUID) -> ShowIssue {
        ShowIssue(severity: severity, kind: severity == .warning ? .startMismatch : .missingMaster, songID: song, title: "t", message: message)
    }

    func testWarningsHideAndComeBackWhenTheyChange() throws {
        let id = UUID()
        var show = Show(name: "x")
        let oneFrame = issue(.warning, "1 frame after the sheet", song: id)
        show.dismiss(oneFrame)
        XCTAssertTrue(show.isDismissed(oneFrame))
        XCTAssertFalse(show.isDismissed(issue(.warning, "3 frames after the sheet", song: id)), "a changed problem shows again")
        XCTAssertFalse(show.isDismissed(issue(.warning, "1 frame after the sheet", song: UUID())), "only for that song")

        // Saved with the show.
        let data = try JSONEncoder().encode(show)
        XCTAssertTrue(try JSONDecoder().decode(Show.self, from: data).isDismissed(oneFrame))

        show.restore(oneFrame)
        XCTAssertFalse(show.isDismissed(oneFrame))
    }

    func testErrorsCantBeHidden() {
        var show = Show(name: "x")
        let missing = issue(.error, "No master file is matched", song: UUID())
        show.dismiss(missing)
        XCTAssertFalse(show.isDismissed(missing))
        XCTAssertNil(show.dismissedIssues)
    }

    func testPruneForgetsFindingsThatAreGone() {
        let id = UUID()
        var show = Show(name: "x")
        let a = issue(.warning, "a", song: id), b = issue(.warning, "b", song: id)
        show.dismiss(a); show.dismiss(b)
        show.pruneDismissed(keeping: [b])
        XCTAssertEqual(show.dismissedIssues, [b.key])
    }

    func testOldShowFilesStillOpen() throws {
        let json = #"{"format":1,"name":"Old","defaultRate":"30","songs":[],"setlists":[],"routing":{"masterChannels":[1,2],"masterGainDB":0,"timecodeGainDB":-6}}"#
        let show = try JSONDecoder().decode(Show.self, from: Data(json.utf8))
        XCTAssertNil(show.dismissedIssues)
    }
}
