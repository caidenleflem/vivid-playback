import Foundation

/// What adding audio to an imported show did.
public struct AttachResult: Equatable, Sendable {
    /// "Night Drive · master", "Night Drive · timecode".
    public var attached: [String] = []
    /// Files no song took (no match, or the song already has that file).
    public var unused: [String] = []
    public var ambiguities: [String] = []

    public var summary: String {
        var parts: [String] = []
        parts.append(attached.isEmpty ? "No files matched a song that needed one." : "Added \(attached.count) \(attached.count == 1 ? "file" : "files").")
        if !unused.isEmpty { parts.append("\(unused.count) not used: \(unused.prefix(4).joined(separator: ", "))\(unused.count > 4 ? "…" : "").") }
        if !ambiguities.isEmpty { parts.append(ambiguities.joined(separator: " ")) }
        return parts.joined(separator: " ")
    }
}

public enum AttachError: Error, CustomStringConvertible, Equatable {
    case noTimecodeInFile(String)

    public var description: String {
        switch self {
        case .noTimecodeInFile(let name): return "\(name) has no readable timecode in it, so it can't set this song's start."
        }
    }
}

extension ShowImporter {
    /// Matches audio files to songs in an imported show, the same way an import does, and fills
    /// in only what's missing: a file never replaces one a song already has.
    public static func attach(_ files: [URL], to show: inout Show) -> AttachResult {
        let audio = files.filter(FileMatcher.isAudio)
        let rows = show.songs.enumerated().map { i, s in
            SheetRow(rowIndex: i, number: s.number, title: s.title, start: s.start, end: nil, length: s.length, rate: s.rate,
                     fileOffset: s.fileOffset, masterFile: nil, timecodeFile: nil, notes: nil)
        }
        let match = FileMatcher.match(rows: rows, files: audio)
        let base = show.mediaFolder.map { URL(fileURLWithPath: $0) }
        func path(_ url: URL) -> String { base.map { ShowStore.relativePath(of: url, in: $0) } ?? url.standardizedFileURL.path }
        var result = AttachResult(ambiguities: match.ambiguities)
        var used = Set<URL>()
        for i in show.songs.indices {
            guard let m = match.matches[i] else { continue }
            if show.songs[i].masterPath == nil, let url = m.master {
                show.songs[i].masterPath = path(url)
                used.insert(url)
                result.attached.append("\(show.songs[i].title) · master")
            }
            if show.songs[i].hasTimecode, show.songs[i].timecodePath == nil, let url = m.timecode {
                show.songs[i].timecodePath = path(url)
                show.songs[i].timecodeFileChannel = nil
                used.insert(url)
                result.attached.append("\(show.songs[i].title) · timecode")
            }
        }
        result.unused = audio.filter { !used.contains($0) }.map(\.lastPathComponent).sorted()
        return result
    }

    /// Sets one song's master or timecode file (replacing any it had). Giving a timecode file
    /// to a song the sheet left without timecode reads the file's LTC and takes its start from
    /// there; the caller shows the person what was found.
    @discardableResult
    public static func assign(_ url: URL, role: AudioRole, songID: UUID, in show: inout Show,
                              reader: AudioFileReading) throws -> Song? {
        guard let i = show.songs.firstIndex(where: { $0.id == songID }) else { return nil }
        let base = show.mediaFolder.map { URL(fileURLWithPath: $0) }
        let path = base.map { ShowStore.relativePath(of: url, in: $0) } ?? url.standardizedFileURL.path
        switch role {
        case .timecode:
            if !show.songs[i].hasTimecode {
                let audio = try reader.readChannels(of: url)
                guard let found = LTCAnalyzer.analyze(channels: audio.channels, sampleRate: audio.sampleRate),
                      let start = found.analysis.atFileStart else { throw AttachError.noTimecodeInFile(url.lastPathComponent) }
                show.songs[i].start = start
                show.songs[i].fileOffset = 0
                show.songs[i].timecodeOff = nil
                show.songs[i].timecodeFileChannel = found.channel
            } else {
                show.songs[i].timecodeFileChannel = nil
            }
            show.songs[i].timecodePath = path
        case .master, .other:
            show.songs[i].masterPath = path
        }
        return show.songs[i]
    }

    /// Takes a file off a song.
    public static func remove(_ role: AudioRole, songID: UUID, in show: inout Show) {
        guard let i = show.songs.firstIndex(where: { $0.id == songID }) else { return }
        if role == .timecode {
            show.songs[i].timecodePath = nil
            show.songs[i].timecodeFileChannel = nil
        } else {
            show.songs[i].masterPath = nil
        }
    }

    /// Files, with folders opened up (three levels deep).
    public static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue ? listFiles(in: url) : [url]
        }
    }
}
