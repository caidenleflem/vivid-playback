import Foundation

public struct ImportReport: Sendable {
    public var show: Show
    public var sheetURL: URL?
    public var sheetProblems: [String]
    public var ambiguities: [String]
    public var unmatchedFiles: [String]
    public var issues: [ShowIssue]
    /// Which channel of each song's timecode file holds the LTC, by song.
    public var timecodeChannel: [UUID: Int]

    public var masterCount: Int { show.songs.filter { $0.masterPath != nil }.count }
    public var timecodeCount: Int { show.songs.filter { $0.timecodePath != nil }.count }
    public var readyCount: Int {
        let blocked = Set(issues.filter { $0.severity == .error || $0.kind == .startMismatch }.compactMap(\.songID))
        return show.songs.filter { !blocked.contains($0.id) }.count
    }
}

public enum ImportStep: Sendable, Equatable {
    case scanning
    case readingSheet(String)
    case matching
    case checking(song: String, index: Int, of: Int)
    case done
}

public enum ImportError: Error, CustomStringConvertible, Equatable {
    case noSheet
    case spreadsheetNeedsExport(String)
    case emptySheet(String)
    case unreadableSheet(String)

    public var description: String {
        switch self {
        case .noSheet: return "There's no offset sheet in the folder. Add a CSV or tab-separated export of it."
        case .spreadsheetNeedsExport(let name): return "\(name) can't be read directly. Export it as .xlsx or CSV (in Numbers: File › Export To) and drop the folder again."
        case .emptySheet(let name): return "\(name) has no songs in it that could be read."
        case .unreadableSheet(let name): return "\(name) couldn't be opened. Save it again from Excel or Numbers, or export it as CSV."
        }
    }
}

/// Turns a show folder into a checked show: finds the sheet, reads it, matches the audio, reads
/// every timecode file and reports anything that doesn't line up.
public struct ShowImporter: Sendable {
    public var reader: AudioFileReading
    public var defaultRate: FrameRate

    public init(reader: AudioFileReading = WAVFile(), defaultRate: FrameRate = .fps30) {
        self.reader = reader
        self.defaultRate = defaultRate
    }

    static let sheetExtensions: Set<String> = ["csv", "tsv", "txt", "xlsx"]
    static let spreadsheetExtensions: Set<String> = ["xls", "numbers"]

    public static func listFiles(in folder: URL, depth: Int = 3) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if depth > 0 && url.pathExtension != ShowStore.fileExtension { out += listFiles(in: url, depth: depth - 1) }
            } else {
                out.append(url)
            }
        }
        return out
    }

    /// The sheet to use: a name that says what it is wins ("Tour Offsets.csv"), else the first.
    static func pickSheet(_ files: [URL]) -> URL? {
        let sheets = files.filter { sheetExtensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("~$") }
        let words = ["offset", "timecode", "tc", "sheet", "setlist", "cue"]
        return sheets.first { url in words.contains { url.lastPathComponent.lowercased().contains($0) } } ?? sheets.first
    }

    /// Reads a CSV, tab-separated or Excel (.xlsx) offset sheet.
    public static func readSheet(_ url: URL, mapping: ColumnMapping? = nil, defaultRate: FrameRate = .fps30) throws -> OffsetSheet {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "xlsx" {
            guard let table = try? XLSXReader.table(from: data) else { throw ImportError.unreadableSheet(url.lastPathComponent) }
            return OffsetSheetParser.read(table: table, mapping: mapping, defaultRate: defaultRate)
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return OffsetSheetParser.read(text: text, mapping: mapping, defaultRate: defaultRate)
    }

    public func importFolder(_ folder: URL, name: String? = nil, mapping: ColumnMapping? = nil,
                             progress: (@Sendable (ImportStep) -> Void)? = nil) throws -> ImportReport {
        progress?(.scanning)
        let files = Self.listFiles(in: folder)
        guard let sheetURL = Self.pickSheet(files) else {
            if let xl = files.first(where: { Self.spreadsheetExtensions.contains($0.pathExtension.lowercased()) }) {
                throw ImportError.spreadsheetNeedsExport(xl.lastPathComponent)
            }
            throw ImportError.noSheet
        }
        progress?(.readingSheet(sheetURL.lastPathComponent))
        let sheet = try Self.readSheet(sheetURL, mapping: mapping, defaultRate: defaultRate)
        let usable = sheet.rows.filter { $0.start != nil }
        guard !usable.isEmpty else { throw ImportError.emptySheet(sheetURL.lastPathComponent) }

        progress?(.matching)
        let match = FileMatcher.match(rows: usable, files: files)
        var songs: [Song] = []
        for row in usable {
            guard let start = row.start else { continue }
            let m = match.matches[row.rowIndex]
            var length = row.length
            if length == nil, let end = row.end { length = Double(end.frames(since: start)) / start.rate.framesPerSecond }
            songs.append(Song(number: row.number, title: row.title, start: start, fileOffset: row.fileOffset ?? 0, length: length,
                              masterPath: m?.master.map { ShowStore.relativePath(of: $0, in: folder) },
                              timecodePath: m?.timecode.map { ShowStore.relativePath(of: $0, in: folder) },
                              notes: row.notes))
        }
        let rate = songs.first?.rate ?? defaultRate
        var show = Show(name: name ?? folder.lastPathComponent, defaultRate: rate, mediaFolder: folder.standardizedFileURL.path,
                        songs: songs, sheetMapping: sheet.mapping, sheetFile: ShowStore.relativePath(of: sheetURL, in: folder))

        let checked = check(&show, progress: progress)
        for (i, song) in show.songs.enumerated() { show.songs[i].timecodeFileChannel = checked.channels[song.id] }
        show.setlists = [Setlist(name: "Full show", songIDs: show.songs.map(\.id))]
        progress?(.done)
        return ImportReport(show: show, sheetURL: sheetURL, sheetProblems: sheet.problems, ambiguities: match.ambiguities,
                            unmatchedFiles: match.unmatched.map(\.lastPathComponent), issues: checked.issues, timecodeChannel: checked.channels)
    }

    /// Reads every song's files and checks them. Fills in song lengths from the masters where
    /// the sheet didn't give one. Used on import and whenever a saved show is opened.
    public func check(_ show: inout Show, deviceSampleRate: Double? = nil,
                      progress: (@Sendable (ImportStep) -> Void)? = nil) -> (issues: [ShowIssue], channels: [UUID: Int]) {
        var issues: [ShowIssue] = []
        var channels: [UUID: Int] = [:]
        for (i, song) in show.songs.enumerated() {
            progress?(.checking(song: song.title, index: i + 1, of: show.songs.count))
            var report = SongFileReport()
            if let url = show.url(forMediaPath: song.masterPath) {
                do { report.master = try reader.info(of: url) } catch { report.readErrors.append("\(url.lastPathComponent): \(error)") }
            }
            if let url = show.url(forMediaPath: song.timecodePath) {
                do {
                    let audio = try reader.readChannels(of: url)
                    report.timecode = AudioFileInfo(sampleRate: audio.sampleRate, channelCount: audio.channels.count, frameCount: audio.channels.first?.count ?? 0)
                    if let best = LTCAnalyzer.analyze(channels: audio.channels, sampleRate: audio.sampleRate, expectedRate: song.rate) {
                        report.analysis = best.analysis
                        channels[song.id] = best.channel
                    } else {
                        report.analysis = LTCAnalysis(sampleRate: audio.sampleRate, decodedFrames: 0, rate: nil, first: nil, last: nil,
                                                      firstSample: 0, lastSample: 0, jumps: [], dropouts: [])
                    }
                } catch {
                    report.readErrors.append("\(url.lastPathComponent): \(error)")
                }
            }
            // The song runs to the end of the master unless the sheet says otherwise.
            if show.songs[i].length == nil, let m = report.master {
                show.songs[i].length = max(0, m.duration - song.fileOffset)
            }
            issues += ShowValidator.validate(song: show.songs[i], files: report, deviceSampleRate: deviceSampleRate)
        }
        issues += ShowValidator.validate(show: show)
        return (issues, channels)
    }
}
