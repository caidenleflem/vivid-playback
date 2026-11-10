import XCTest
@testable import PlaybackCore

final class LibraryTests: XCTestCase {
    func show() -> Show {
        let r = FrameRate.fps30
        let songs = [
            Song(number: 3, title: "July", start: Timecode("00:10:00:00", rate: r)!, length: 162),
            Song(number: 1, title: "Interstitial 1", start: Timecode("04:00:00:00", rate: r)!, length: 97),
            Song(number: 2, title: "Intro", start: Timecode("00:00:00:00", rate: r)!, length: 72),
            { var s = Song(number: nil, title: "Pre Encore", start: Timecode(frameCount: 0, rate: r), length: 179); s.timecodeOff = true; return s }(),
        ]
        return Show(name: "x", songs: songs, setlists: [Setlist(name: "Full show", songIDs: songs.map(\.id))])
    }

    func titles(_ ids: [UUID], _ show: Show) -> [String] { ids.compactMap { show.song(id: $0)?.title } }

    func testSorts() {
        let s = show()
        let list = s.setlists[0]
        XCTAssertEqual(titles(list.songIDs(sortedBy: .setlist, in: s), s), ["July", "Interstitial 1", "Intro", "Pre Encore"])
        XCTAssertEqual(titles(list.songIDs(sortedBy: .number, in: s), s), ["Interstitial 1", "Intro", "July", "Pre Encore"])
        XCTAssertEqual(titles(list.songIDs(sortedBy: .title, in: s), s), ["Interstitial 1", "Intro", "July", "Pre Encore"])
        XCTAssertEqual(titles(list.songIDs(sortedBy: .start, in: s), s), ["Intro", "July", "Interstitial 1", "Pre Encore"], "no-timecode songs last")
        XCTAssertEqual(titles(list.songIDs(sortedBy: .length, in: s), s), ["Intro", "Interstitial 1", "July", "Pre Encore"])
        XCTAssertEqual(list.duration(in: s), 162 + 97 + 72 + 179)
    }

    func testMoves() {
        let s = show()
        var list = s.setlists[0]
        let ids = list.songIDs
        list.move([ids[3]], before: ids[0])
        XCTAssertEqual(titles(list.songIDs, s), ["Pre Encore", "July", "Interstitial 1", "Intro"])
        list.move([ids[0], ids[2]], before: nil)
        XCTAssertEqual(titles(list.songIDs, s), ["Pre Encore", "Interstitial 1", "July", "Intro"])
        list.moveUp(ids[2])
        XCTAssertEqual(titles(list.songIDs, s), ["Pre Encore", "Interstitial 1", "Intro", "July"])
        list.moveDown(ids[3])
        XCTAssertEqual(titles(list.songIDs, s), ["Interstitial 1", "Pre Encore", "Intro", "July"])
        list.moveUp(ids[1])
        XCTAssertEqual(list.songIDs.first, ids[1], "already at the top stays put")
    }

    func testRemoveAndAddBack() {
        let s = show()
        var list = s.setlists[0]
        let id = list.songIDs[1]
        list.skipped.insert(id)
        list.remove(id)
        XCTAssertFalse(list.songIDs.contains(id))
        XCTAssertFalse(list.skipped.contains(id))
        XCTAssertNotNil(s.song(id: id), "still in the show")
        list.add(id)
        list.add(id)
        XCTAssertEqual(list.songIDs.last, id)
        XCTAssertEqual(list.songIDs.filter { $0 == id }.count, 1)
    }

    func testArtistAndPartsComeFromTheSheet() throws {
        let sheet = OffsetSheetParser.read(text: RealSheetTests.csv)
        XCTAssertEqual(sheet.artistAndShow?.artist, "EXAMPLE ARTIST")
        XCTAssertEqual(sheet.artistAndShow?.show, "EXAMPLE TOUR · FALL 26")
        XCTAssertEqual(sheet.mapping.columns[.part], 1)
        XCTAssertEqual(sheet.rows.first?.part, "Interstitial")
        XCTAssertEqual(sheet.rows[1].part, "Act 1")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Songs.csv")
        try RealSheetTests.csv.write(to: url, atomically: true, encoding: .utf8)
        let report = try ShowImporter().importFolder(dir, sheet: url, scanAudio: false)
        XCTAssertEqual(report.show.artist, "EXAMPLE ARTIST")
        XCTAssertEqual(report.show.name, "EXAMPLE TOUR · FALL 26")
        XCTAssertEqual(report.show.songs[1].part, "Act 1")

        // Saved shows are listed for the Albums page.
        try ShowStore.save(report.show, to: dir.appendingPathComponent("A.vividshow"))
        let library = ShowLibrary.list(in: dir)
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library.first?.show.artist, "EXAMPLE ARTIST")

        // Covers are copied into the package.
        let img = dir.appendingPathComponent("cover.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: img)
        let path = try ShowLibrary.storeArtwork(img, for: report.show.setlists[0], in: dir.appendingPathComponent("A.vividshow"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A.vividshow").appendingPathComponent(path).path))
    }

    func testNewShowsNeverReplaceAnExistingOne() {
        let folder = URL(fileURLWithPath: "/shows")
        let taken: Set<String> = ["/shows/Tour.vividshow", "/shows/Tour 2.vividshow"]
        let url = ShowLibrary.uniquePackageURL(named: "Tour", in: folder) { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "Tour 3.vividshow")
        XCTAssertEqual(ShowLibrary.uniquePackageURL(named: "New", in: folder) { _ in false }.lastPathComponent, "New.vividshow")
        XCTAssertEqual(ShowLibrary.uniquePackageURL(named: "A/B: C", in: folder) { _ in false }.lastPathComponent, "A-B- C.vividshow")
        XCTAssertEqual(ShowLibrary.uniquePackageURL(named: "  ", in: folder) { _ in false }.lastPathComponent, "Show.vividshow")
    }

    func testAlbumSearch() {
        XCTAssertTrue(ShowLibrary.matches("", artist: nil, show: "Tour", setlist: "Full show"))
        XCTAssertTrue(ShowLibrary.matches("beyonce", artist: "Beyoncé", show: "Renaissance", setlist: "Main"))
        XCTAssertTrue(ShowLibrary.matches("main ren", artist: "Beyoncé", show: "Renaissance", setlist: "Main"))
        XCTAssertFalse(ShowLibrary.matches("main festival", artist: "Beyoncé", show: "Renaissance", setlist: "Main"))
        XCTAssertTrue(ShowLibrary.matches("  FULL  ", artist: nil, show: "Tour", setlist: "Full show"))
    }

    func testArtistsAreListedOnce() {
        func entry(_ artist: String?) -> ShowLibrary.Entry {
            var show = Show(name: "x")
            show.artist = artist
            return ShowLibrary.Entry(url: URL(fileURLWithPath: "/x"), show: show)
        }
        XCTAssertEqual(ShowLibrary.artists(in: [entry("Muse"), entry("arctic Monkeys"), entry("muse"), entry(nil), entry(" ")]),
                       ["arctic Monkeys", "Muse"])
    }
}
