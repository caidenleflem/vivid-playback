import Foundation

public enum AudioRole: String, Codable, Sendable {
    case master, timecode
    /// Click, guide and other files that aren't auto-matched.
    case other
}

public struct FileMatch: Equatable, Sendable {
    public var master: URL?
    public var timecode: URL?
}

public struct MatchResult: Equatable, Sendable {
    /// Keyed by the sheet row index.
    public var matches: [Int: FileMatch]
    /// Audio files no row claimed.
    public var unmatched: [URL]
    /// Rows where more than one file fits, in plain words. These are never guessed.
    public var ambiguities: [String]
}

/// Pairs the audio files in a show folder with the rows of the offset sheet.
public enum FileMatcher {
    public static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "mp3", "m4a", "caf", "flac"]

    static let timecodeTokens: Set<String> = ["ltc", "tc", "timecode", "smpte", "tcode"]
    static let otherTokens: Set<String> = ["click", "guide", "cues", "cue", "stem", "stems", "count", "countin", "vox", "talkback"]
    static let roleWords: Set<String> = timecodeTokens.union(["master", "mstr", "mix", "final", "print"])

    public static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }

    static func tokens(_ name: String) -> [String] {
        let base = (name as NSString).deletingPathExtension.lowercased()
        // Split "NightDrive_LTC", "03-night drive (ltc)" and "03NightDrive" into words and numbers.
        var out: [String] = []
        var current = ""
        var lastWasDigit: Bool?
        for ch in base {
            if ch.isLetter || ch.isNumber {
                let digit = ch.isNumber
                if let last = lastWasDigit, last != digit, !current.isEmpty { out.append(current); current = "" }
                current.append(ch)
                lastWasDigit = digit
            } else {
                if !current.isEmpty { out.append(current) }
                current = ""
                lastWasDigit = nil
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    public static func role(forFileName name: String) -> AudioRole {
        let t = Set(tokens(name))
        if !t.isDisjoint(with: timecodeTokens) { return .timecode }
        if !t.isDisjoint(with: otherTokens) { return .other }
        return .master
    }

    /// The song number in a file name: the first number of one to three digits
    /// ("03 Night Drive.wav", "Tour 2027 - 03 - Night Drive", "Song3_LTC.wav").
    public static func songNumber(inFileName name: String) -> Int? {
        for t in tokens(name) where t.allSatisfy(\.isNumber) && (1...3).contains(t.count) {
            return Int(t)
        }
        return nil
    }

    static func titleKey(_ s: String) -> String {
        tokens(s).filter { !$0.allSatisfy(\.isNumber) && !roleWords.contains($0) }.joined()
    }

    /// `roles` overrides the name-based role for files whose content was checked.
    public static func match(rows: [SheetRow], files: [URL], roles: [URL: AudioRole] = [:]) -> MatchResult {
        let audio = files.filter(isAudio)
        var claimed = Set<URL>()
        var matches: [Int: FileMatch] = [:]
        var ambiguities: [String] = []
        let byRole = Dictionary(grouping: audio, by: { roles[$0] ?? role(forFileName: $0.lastPathComponent) })

        func named(_ name: String) -> URL? {
            let wanted = name.lowercased()
            let wantedBase = (wanted as NSString).deletingPathExtension
            return audio.first { url in
                let n = url.lastPathComponent.lowercased()
                return n == wanted || (n as NSString).deletingPathExtension == wantedBase
            }
        }

        for row in rows {
            var m = FileMatch()
            for role in [AudioRole.master, .timecode] {
                // 1. The sheet names the file.
                if let name = role == .master ? row.masterFile : row.timecodeFile {
                    if let url = named(name) {
                        if role == .master { m.master = url } else { m.timecode = url }
                        claimed.insert(url)
                        continue
                    }
                }
                let pool = (byRole[role] ?? []).filter { !claimed.contains($0) }
                // 2. The song number, as long as the file's own title (if it has one) agrees.
                // 3. Otherwise the title alone.
                let key = titleKey(row.title)
                func titleAgrees(_ url: URL) -> Bool {
                    let fileKey = titleKey(url.lastPathComponent)
                    return fileKey.isEmpty || key.isEmpty || fileKey.contains(key) || key.contains(fileKey)
                }
                var candidates: [URL] = []
                if let n = row.number {
                    candidates = pool.filter { songNumber(inFileName: $0.lastPathComponent) == n && titleAgrees($0) }
                }
                if candidates.isEmpty && !key.isEmpty {
                    let exact = pool.filter { titleKey($0.lastPathComponent) == key }
                    candidates = exact.isEmpty ? pool.filter { titleKey($0.lastPathComponent).contains(key) } : exact
                } else if candidates.count > 1 && !key.isEmpty {
                    let exact = candidates.filter { titleKey($0.lastPathComponent) == key }
                    if exact.count == 1 { candidates = exact }
                }
                if candidates.count == 1 {
                    if role == .master { m.master = candidates[0] } else { m.timecode = candidates[0] }
                    claimed.insert(candidates[0])
                } else if candidates.count > 1 {
                    let names = candidates.map(\.lastPathComponent).sorted().joined(separator: ", ")
                    ambiguities.append("\(row.title): more than one \(role == .master ? "master" : "timecode") file fits (\(names)). Pick one.")
                }
            }
            matches[row.rowIndex] = m
        }
        let unmatched = audio.filter { !claimed.contains($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return MatchResult(matches: matches, unmatched: unmatched, ambiguities: ambiguities)
    }
}
