import Foundation

/// CSV and tab-separated text, with quoted fields, as exported by Numbers, Excel and Google Sheets.
public enum DelimitedText {
    public static func parse(_ text: String) -> [[String]] {
        parse(text, delimiter: detectDelimiter(text))
    }

    public static func detectDelimiter(_ text: String) -> Character {
        let sample = text.split(whereSeparator: \.isNewline).prefix(10)
        let candidates: [Character] = ["\t", ",", ";"]
        var best: Character = ","
        var bestScore = -1
        for d in candidates {
            let counts = sample.map { line in line.filter { $0 == d }.count }
            guard let first = counts.first, first > 0 else { continue }
            // Prefer the delimiter that appears on most lines.
            let score = counts.filter { $0 > 0 }.count * 100 + counts.reduce(0, +)
            if score > bestScore { best = d; bestScore = score }
        }
        return best
    }

    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        func endField() { row.append(field.trimmingCharacters(in: .whitespaces)); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.trimmingCharacters(in: .whitespaces).isEmpty {
                field = ""
                inQuotes = true
            } else if c == delimiter {
                endField()
            } else if c.isNewline {
                endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

/// The things an offset sheet can say about a song.
public enum SheetField: String, Codable, CaseIterable, Sendable {
    case number, title, start, end, length, rate, fileOffset, masterFile, timecodeFile, notes

    public var displayName: String {
        switch self {
        case .number: return "Song number"
        case .title: return "Title"
        case .start: return "Timecode start"
        case .end: return "Timecode end"
        case .length: return "Length"
        case .rate: return "Frame rate"
        case .fileOffset: return "File offset"
        case .masterFile: return "Master file"
        case .timecodeFile: return "Timecode file"
        case .notes: return "Notes"
        }
    }
}

extension SheetField: CodingKeyRepresentable {}

/// Which column holds which field. `headerRow` is the row index of the header, or nil if the
/// sheet has none. Saved with the show, so a sheet layout is only mapped once.
public struct ColumnMapping: Codable, Hashable, Sendable {
    public var columns: [SheetField: Int]
    public var headerRow: Int?

    public init(columns: [SheetField: Int] = [:], headerRow: Int? = nil) {
        self.columns = columns
        self.headerRow = headerRow
    }

    /// The minimum to build songs: a title and a start timecode.
    public var isUsable: Bool { columns[.title] != nil && columns[.start] != nil }
}

public struct SheetRow: Equatable, Sendable {
    public var rowIndex: Int
    public var number: Int?
    public var title: String
    public var start: Timecode?
    public var end: Timecode?
    public var length: Double?
    public var rate: FrameRate?
    public var fileOffset: Double?
    public var masterFile: String?
    public var timecodeFile: String?
    public var notes: String?
}

public struct OffsetSheet: Sendable {
    public var table: [[String]]
    public var mapping: ColumnMapping
    public var rows: [SheetRow]
    /// Rows that couldn't be read, in plain words ("Row 7: couldn't read the start timecode “1:00”.").
    public var problems: [String]

    public var headers: [String] {
        guard let h = mapping.headerRow, h < table.count else { return [] }
        return table[h]
    }
}

public enum OffsetSheetParser {
    // Header names are compared lowercased with everything but letters and digits removed.
    static let synonyms: [(SheetField, [String])] = [
        (.timecodeFile, ["ltcfile", "tcfile", "timecodefile", "ltc", "smpte", "smptefile", "ltcaudio", "timecodeaudio"]),
        (.masterFile, ["masterfile", "master", "masteraudio", "audiofile", "audio", "mix", "file", "filename", "wav"]),
        (.number, ["number", "no", "num", "songno", "songnumber", "songnum", "track", "trackno", "tracknumber", "cue", "id"]),
        (.title, ["title", "song", "songtitle", "songname", "name", "trackname", "tracktitle"]),
        (.start, ["tcstart", "starttc", "start", "tcin", "in", "starttimecode", "timecodestart", "timecodein", "timecode", "tc", "tcoffset", "timecodeoffset", "offsettc", "songoffset", "offset", "starttime"]),
        (.end, ["tcend", "endtc", "end", "tcout", "out", "endtimecode", "timecodeend", "timecodeout", "endtime"]),
        (.length, ["length", "duration", "len", "time", "runtime", "songlength"]),
        (.rate, ["fps", "framerate", "rate", "fr", "frames"]),
        (.fileOffset, ["fileoffset", "preroll", "audiooffset", "prerollsec", "prerollseconds", "fileoffsetsec", "headroom"]),
        (.notes, ["notes", "note", "comments", "comment", "remarks"]),
    ]

    static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "mp3", "m4a", "caf", "flac"]

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    enum Kind { case timecode, number, filename, duration, text, empty }

    static func kind(of value: String) -> Kind {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return .empty }
        let ext = (v as NSString).pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .filename }
        if Timecode(v, rate: .fps30) != nil && v.split(whereSeparator: { $0 == ":" || $0 == ";" }).count == 4 { return .timecode }
        if Double(v.replacingOccurrences(of: ",", with: ".")) != nil { return .number }
        if TimeFormat.parseDuration(v) != nil && v.contains(":") { return .duration }
        return .text
    }

    static func profile(_ table: [[String]], column: Int, from: Int) -> [Kind: Double] {
        var counts: [Kind: Int] = [:]
        var total = 0
        for row in table.dropFirst(from) where column < row.count {
            let k = kind(of: row[column])
            if k == .empty { continue }
            counts[k, default: 0] += 1
            total += 1
        }
        guard total > 0 else { return [:] }
        return counts.mapValues { Double($0) / Double(total) }
    }

    /// Guesses which column holds what, from header names and from what the values look like.
    public static func guessMapping(_ table: [[String]]) -> ColumnMapping {
        // The header is the first row (of the first ten) where two or more cells name a field.
        var headerRow: Int?
        for (i, row) in table.prefix(10).enumerated() {
            let hits = row.filter { cell in
                let n = normalize(cell)
                return cell.trimmingCharacters(in: .whitespaces) == "#" || synonyms.contains { $0.1.contains(n) }
            }.count
            if hits >= 2 { headerRow = i; break }
        }
        let dataStart = (headerRow ?? -1) + 1
        let width = table.map(\.count).max() ?? 0
        var columns: [SheetField: Int] = [:]
        var used = Set<Int>()
        let profiles = (0..<width).map { profile(table, column: $0, from: dataStart) }

        func assign(_ field: SheetField, _ col: Int) {
            guard columns[field] == nil, !used.contains(col) else { return }
            columns[field] = col
            used.insert(col)
        }

        if let h = headerRow {
            let header = table[h]
            // Exact header names first, then headers that contain a name ("Song Title (final)").
            for exact in [true, false] {
                for (field, names) in synonyms {
                    for (col, cell) in header.enumerated() where !used.contains(col) && columns[field] == nil {
                        let n = normalize(cell)
                        let isHash = cell.contains("#") && field == .number
                        let hit = isHash || (exact ? names.contains(n) : (n.count > 2 && names.contains { $0.count > 2 && n.contains($0) }))
                        guard hit else { continue }
                        let p = profiles[col]
                        // Let the values overrule an ambiguous header.
                        switch field {
                        case .start, .end:
                            if (p[.filename] ?? 0) > 0.5 { assign(.timecodeFile, col); continue }
                            if (p[.timecode] ?? 0) < 0.5 {
                                // "Offset" holding plain seconds is a file offset, not a start timecode.
                                if (p[.number] ?? 0) > 0.5 && n.contains("offset") { assign(.fileOffset, col) }
                                continue
                            }
                        case .masterFile, .timecodeFile:
                            if (p[.filename] ?? 0) < 0.5 && (p[.text] ?? 0) < 0.5 { continue }
                        case .number:
                            if (p[.number] ?? 0) < 0.5 { continue }
                        case .rate:
                            if (p[.timecode] ?? 0) > 0.5 { continue }
                        default:
                            break
                        }
                        assign(field, col)
                    }
                }
            }
        }

        // An "Offset" column of plain seconds next to a separate start column is a file offset.
        if let h = headerRow, columns[.fileOffset] == nil {
            for (col, cell) in table[h].enumerated() where !used.contains(col) && normalize(cell).contains("offset") {
                let p = profiles[col]
                if (p[.number] ?? 0) + (p[.duration] ?? 0) > 0.5 { assign(.fileOffset, col) }
            }
        }

        // No header, or fields the header didn't name: infer from the values.
        if columns[.start] == nil, let col = (0..<width).first(where: { !used.contains($0) && (profiles[$0][.timecode] ?? 0) >= 0.6 }) {
            assign(.start, col)
        }
        if columns[.title] == nil, let col = (0..<width).first(where: { !used.contains($0) && (profiles[$0][.text] ?? 0) >= 0.6 }) {
            assign(.title, col)
        }
        if headerRow == nil {
            if columns[.number] == nil, let col = (0..<width).first(where: { !used.contains($0) && (profiles[$0][.number] ?? 0) >= 0.9 }), col < (columns[.title] ?? width) {
                assign(.number, col)
            }
            let files = (0..<width).filter { !used.contains($0) && (profiles[$0][.filename] ?? 0) >= 0.6 }
            for col in files {
                let names = table.dropFirst(dataStart).compactMap { col < $0.count ? $0[col] : nil }
                let tcLike = names.filter { FileMatcher.role(forFileName: $0) == .timecode }.count
                assign(tcLike * 2 > names.count ? .timecodeFile : .masterFile, col)
            }
        }
        return ColumnMapping(columns: columns, headerRow: headerRow)
    }

    /// Reads rows using `mapping`. Rows with no title and no start are skipped as blank or
    /// section rows; a row with a title but an unreadable start is reported, never guessed.
    public static func readRows(_ table: [[String]], mapping: ColumnMapping, defaultRate: FrameRate) -> (rows: [SheetRow], problems: [String]) {
        var rows: [SheetRow] = []
        var problems: [String] = []
        let start = (mapping.headerRow ?? -1) + 1
        for index in start..<max(start, table.count) {
            let cells = table[index]
            func cell(_ f: SheetField) -> String? {
                guard let c = mapping.columns[f], c < cells.count else { return nil }
                let v = cells[c].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            let title = cell(.title)
            let startText = cell(.start)
            if title == nil && startText == nil { continue }
            let rowLabel = "Row \(index + 1)"
            var rate = defaultRate
            if let r = cell(.rate) {
                if let parsed = FrameRate.parse(r) { rate = parsed } else { problems.append("\(rowLabel): couldn't read the frame rate “\(r)”; using \(defaultRate.displayName).") }
            }
            var row = SheetRow(rowIndex: index, number: nil, title: title ?? "Untitled", start: nil, end: nil, length: nil,
                               rate: cell(.rate) == nil ? nil : rate, fileOffset: nil,
                               masterFile: cell(.masterFile), timecodeFile: cell(.timecodeFile), notes: cell(.notes))
            if let n = cell(.number) { row.number = Int(n.filter(\.isNumber)) }
            if let s = startText {
                row.start = Timecode(s, rate: rate)
                if row.start == nil { problems.append("\(rowLabel) (\(row.title)): couldn't read the start timecode “\(s)”.") }
            } else {
                problems.append("\(rowLabel) (\(row.title)): no start timecode.")
            }
            if let e = cell(.end) {
                row.end = Timecode(e, rate: rate)
                if row.end == nil { problems.append("\(rowLabel) (\(row.title)): couldn't read the end timecode “\(e)”.") }
            }
            if let l = cell(.length) {
                if let tc = Timecode(l, rate: rate), l.split(whereSeparator: { $0 == ":" || $0 == ";" }).count == 4 {
                    row.length = tc.seconds
                } else {
                    row.length = TimeFormat.parseDuration(l)
                }
                if row.length == nil { problems.append("\(rowLabel) (\(row.title)): couldn't read the length “\(l)”.") }
            }
            if let o = cell(.fileOffset) {
                let cleaned = o.replacingOccurrences(of: "+", with: "")
                if let tc = Timecode(cleaned, rate: rate), cleaned.contains(":") {
                    row.fileOffset = tc.seconds
                } else {
                    row.fileOffset = TimeFormat.parseDuration(cleaned)
                }
                if row.fileOffset == nil { problems.append("\(rowLabel) (\(row.title)): couldn't read the file offset “\(o)”.") }
            }
            rows.append(row)
        }
        return (rows, problems)
    }

    /// The rate most rows use, or `fallback`.
    public static func commonRate(_ table: [[String]], mapping: ColumnMapping, fallback: FrameRate) -> FrameRate {
        guard let col = mapping.columns[.rate] else { return fallback }
        let start = (mapping.headerRow ?? -1) + 1
        var counts: [FrameRate: Int] = [:]
        for row in table.dropFirst(start) where col < row.count {
            if let r = FrameRate.parse(row[col]) { counts[r, default: 0] += 1 }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? fallback
    }

    public static func read(text: String, mapping: ColumnMapping? = nil, defaultRate: FrameRate = .fps30) -> OffsetSheet {
        read(table: DelimitedText.parse(text), mapping: mapping, defaultRate: defaultRate)
    }

    public static func read(table: [[String]], mapping: ColumnMapping? = nil, defaultRate: FrameRate = .fps30) -> OffsetSheet {
        let map = mapping ?? guessMapping(table)
        let rate = commonRate(table, mapping: map, fallback: defaultRate)
        var problems: [String] = []
        if map.columns[.title] == nil { problems.append("Couldn't find a title column. Choose one in the column mapping.") }
        if map.columns[.start] == nil { problems.append("Couldn't find a start timecode column. Choose one in the column mapping.") }
        let result = readRows(table, mapping: map, defaultRate: rate)
        return OffsetSheet(table: table, mapping: map, rows: result.rows, problems: problems + result.problems)
    }
}
