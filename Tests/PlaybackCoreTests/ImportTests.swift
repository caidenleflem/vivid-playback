import XCTest
@testable import PlaybackCore

final class ImportTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("Example Tour \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Masters"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Timecode"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Writes a 3-second master (a quiet tone) and a matching LTC file.
    func writeSong(_ n: Int, _ title: String, tcStart: String, rate: FrameRate = .fps30, tcSeconds: Double = 3, sampleRate: Int = 48_000) throws {
        let sr = Double(sampleRate)
        let master = (0..<(sampleRate * 3)).map { Float(sin(Double($0) * 2 * .pi * 220 / sr)) * 0.2 }
        try WAVFile.write(channels: [master, master], sampleRate: 48_000, bitDepth: 16,
                          to: dir.appendingPathComponent("Masters/\(String(format: "%02d", n)) \(title).wav"))
        let frames = Int(tcSeconds * rate.framesPerSecond)
        let ltc = LTC.render(start: Timecode(tcStart, rate: rate)!, frameCount: frames, sampleRate: sr)
        try WAVFile.write(channels: [ltc], sampleRate: sampleRate, bitDepth: 16,
                          to: dir.appendingPathComponent("Timecode/\(String(format: "%02d", n)) \(title) LTC.wav"))
    }

    func testImportsAndChecksAFolder() throws {
        try """
        Song #,Title,TC Start,FPS
        1,Overture,01:00:00:00,30
        2,Golden Hour,02:00:00:00,30
        3,Afterglow,04:00:00:00,30
        """.write(to: dir.appendingPathComponent("Tour Offsets.csv"), atomically: true, encoding: .utf8)
        try writeSong(1, "Overture", tcStart: "01:00:00:00")
        try writeSong(2, "Golden Hour", tcStart: "02:00:00:00")
        try writeSong(3, "Afterglow", tcStart: "04:00:00:01")  // one frame late
        try Data().write(to: dir.appendingPathComponent("Masters/Count-in click.wav"))

        let steps = StepLog()
        let report = try ShowImporter().importFolder(dir, name: "Example Tour 2027", progress: { steps.add($0) })
        XCTAssertEqual(report.show.songs.count, 3)
        XCTAssertEqual(report.masterCount, 3)
        XCTAssertEqual(report.timecodeCount, 3)
        XCTAssertEqual(report.unmatchedFiles, ["Count-in click.wav"])
        XCTAssertEqual(report.show.songs[0].masterPath, "Masters/01 Overture.wav")
        XCTAssertEqual(report.show.songs[0].length ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(report.issues.count, 1, report.issues.map(\.message).joined(separator: "\n"))
        let issue = try XCTUnwrap(report.issues.first)
        XCTAssertEqual(issue.kind, .startMismatch)
        XCTAssertEqual(issue.title, "Afterglow needs a look")
        XCTAssertTrue(issue.message.contains("04:00:00:01, 1 frame after the sheet (04:00:00:00)"), issue.message)
        XCTAssertEqual(report.readyCount, 2)
        XCTAssertEqual(steps.all.last, .done)
        XCTAssertEqual(report.show.setlists.first?.songIDs.count, 3)

        // Saves and reopens.
        let package = dir.appendingPathComponent("Example.vividshow")
        try ShowStore.save(report.show, to: package)
        let reopened = try ShowStore.load(from: package)
        XCTAssertEqual(reopened, report.show)
        XCTAssertEqual(reopened.url(forMediaPath: reopened.songs[0].masterPath)?.lastPathComponent, "01 Overture.wav")
    }

    func testRateAndLengthProblemsAreReported() throws {
        try "Title,TC Start,FPS\nNight Drive,03:00:00:00,30\n".write(to: dir.appendingPathComponent("offsets.csv"), atomically: true, encoding: .utf8)
        try writeSong(3, "Night Drive", tcStart: "03:00:00:00", rate: .fps25, tcSeconds: 2)
        let report = try ShowImporter().importFolder(dir)
        let kinds = Set(report.issues.map(\.kind))
        XCTAssertTrue(kinds.contains(.rateMismatch), "\(kinds)")
        XCTAssertTrue(kinds.contains(.lengthMismatch), "\(kinds)")
    }

    func testMissingSheetAndSpreadsheets() throws {
        XCTAssertThrowsError(try ShowImporter().importFolder(dir)) { XCTAssertEqual($0 as? ImportError, .noSheet) }
        try Data().write(to: dir.appendingPathComponent("Offsets.numbers"))
        XCTAssertThrowsError(try ShowImporter().importFolder(dir)) { XCTAssertEqual($0 as? ImportError, .spreadsheetNeedsExport("Offsets.numbers")) }
    }

    func testOverlapAcrossSongs() {
        let a = Song(title: "Velvet", start: Timecode("10:00:00:00", rate: .fps30)!, length: 300)
        let b = Song(title: "Long Way Home", start: Timecode("10:04:00:00", rate: .fps30)!, length: 200)
        let issues = ShowValidator.validate(show: Show(name: "x", songs: [b, a]))
        XCTAssertEqual(issues.map(\.kind), [.overlap])
        XCTAssertEqual(issues.first?.title, "Velvet runs into Long Way Home")
    }

    func testMissingFilesAreErrors() {
        let song = Song(title: "Encore", start: Timecode("12:00:00:00", rate: .fps30)!)
        let issues = ShowValidator.validate(song: song, files: SongFileReport())
        XCTAssertEqual(Set(issues.map(\.kind)), [.missingMaster, .missingTimecode])
        XCTAssertTrue(issues.allSatisfy { $0.severity == .error })
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ImportStep] = []
    func add(_ s: ImportStep) { lock.lock(); steps.append(s); lock.unlock() }
    var all: [ImportStep] { lock.lock(); defer { lock.unlock() }; return steps }
}

final class ExampleShowTests: XCTestCase {
    func testExampleShowImportsWithOneFinding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Example \(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExampleShow.write(to: dir, seconds: 4)
        var report = try ShowImporter().importFolder(dir, name: "Example Tour 2027")
        XCTAssertEqual(report.show.songs.count, 4)
        XCTAssertEqual(report.issues.map(\.title), ["Afterglow needs a look"])
        XCTAssertEqual(report.readyCount, 3)
        // Re-checking a saved show finds the same thing.
        let again = ShowImporter().check(&report.show)
        XCTAssertEqual(again.issues.map(\.kind), [.startMismatch])
    }
}
