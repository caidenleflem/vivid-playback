import Foundation

/// A one-click fix offered with a finding. Data fixes are applied by `ShowFixer`; the rest are
/// carried out by the app (opening a file picker, moving the playhead).
public enum IssueFix: Hashable, Sendable {
    /// Make the song's start the timecode its file actually reads (the audio doesn't move).
    case useFileStart(Timecode)
    /// Keep the sheet's start; begin the song where the file's timecode reads it.
    case alignToSheet(fileOffset: Double)
    /// Use the frame rate the timecode file runs at.
    case useFileRate(FrameRate)
    case chooseMaster
    case chooseTimecode
    /// Move the playhead to this point of the song (seconds from its start).
    case locate(seconds: Double)
    case audioOutput

    /// Fixes that change the show (off in show mode, and undoable).
    public var changesShow: Bool {
        switch self {
        case .useFileStart, .alignToSheet, .useFileRate, .chooseMaster, .chooseTimecode: return true
        case .locate, .audioOutput: return false
        }
    }
}

public struct ShowIssue: Hashable, Identifiable, Sendable {
    public enum Severity: String, Sendable, Comparable {
        case warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a == .warning && b == .error }
    }

    public enum Kind: String, Sendable {
        case missingMaster, missingTimecode, unreadableFile, noTimecodeFound
        case startMismatch, rateMismatch, timecodeJump, timecodeDropout
        case lengthMismatch, sampleRateMismatch, deviceSampleRate
        case overlap, duplicateStart
    }

    public var id: String { key }
    /// Stable across launches: the song, the kind and the exact wording. If the problem
    /// changes (one frame late becomes three), the wording changes and a hidden finding returns.
    public var key: String { "\(songID?.uuidString ?? "show")|\(kind.rawValue)|\(message)" }
    /// Only warnings can be hidden. A missing master or an unreadable file always shows.
    public var canDismiss: Bool { severity == .warning }
    public var severity: Severity
    public var kind: Kind
    public var songID: UUID?
    /// A short title ("Afterglow needs a look") and the detail in plain words.
    public var title: String
    public var message: String
    /// Ways to fix it, the most likely first.
    public var fixes: [IssueFix] = []
}

/// What was learned about one song's files, for checking.
public struct SongFileReport: Sendable {
    public var master: AudioFileInfo?
    public var timecode: AudioFileInfo?
    public var analysis: LTCAnalysis?
    public var readErrors: [String]

    public init(master: AudioFileInfo? = nil, timecode: AudioFileInfo? = nil, analysis: LTCAnalysis? = nil, readErrors: [String] = []) {
        self.master = master
        self.timecode = timecode
        self.analysis = analysis
        self.readErrors = readErrors
    }
}

/// Checks a show and reports problems. It never changes anything: every finding is shown to
/// the person, who decides.
public enum ShowValidator {
    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }

    public static func validate(song: Song, files: SongFileReport, deviceSampleRate: Double? = nil) -> [ShowIssue] {
        var issues: [ShowIssue] = []
        func add(_ s: ShowIssue.Severity, _ k: ShowIssue.Kind, _ title: String, _ message: String, _ fixes: [IssueFix] = []) {
            issues.append(ShowIssue(severity: s, kind: k, songID: song.id, title: title, message: message, fixes: fixes))
        }
        let name = song.title

        for e in files.readErrors {
            add(.error, .unreadableFile, "\(name) has a file that can't be read", e, song.hasTimecode ? [.chooseMaster, .chooseTimecode] : [.chooseMaster])
        }
        if song.masterPath == nil { add(.error, .missingMaster, "\(name) has no master", "No master file is matched to \(name) yet.", [.chooseMaster]) }
        if song.hasTimecode && song.timecodePath == nil {
            add(.warning, .missingTimecode, "\(name) uses generated timecode",
                "No timecode file is matched to \(name), so timecode is generated from the sheet, starting at \(song.start). Add a timecode file if the console expects a specific one.",
                [.chooseTimecode])
        }

        if song.hasTimecode, let a = files.analysis, let tcInfo = files.timecode {
            if !a.hasTimecode {
                add(.error, .noTimecodeFound, "\(name): no timecode found", "The timecode file has no readable LTC in it. Check it's the right file.", [.chooseTimecode])
            } else {
                if let found = a.rate, found != song.rate {
                    add(.error, .rateMismatch, "\(name): frame rate doesn't match",
                        "The sheet says \(song.rate.displayName), but the timecode file runs at \(found.displayName). The console would drift against the music.",
                        [.useFileRate(found), .chooseTimecode])
                }
                let sample = Int((song.fileOffset * tcInfo.sampleRate).rounded())
                if let readRate = a.rate, let atStart = a.timecode(atSample: sample),
                   let expected = Timecode(song.start.description, rate: readRate) {
                    let delta = atStart.frames(since: expected)
                    if delta != 0 {
                        let amount = plural(abs(delta), "frame")
                        let direction = delta > 0 ? "after" : "before"
                        let where_ = song.fileOffset == 0 ? "starts at" : "reads"
                        var fixes: [IssueFix] = [.useFileStart(atStart)]
                        // Where in the file its timecode reads the sheet's start, if it does.
                        if let first = a.first, a.samplesPerFrame > 0 {
                            let sampleAtSheetStart = Double(a.firstSample) + Double(expected.frames(since: first)) * a.samplesPerFrame
                            if sampleAtSheetStart >= 0 && sampleAtSheetStart <= Double(max(a.lastSample, tcInfo.frameCount)) {
                                fixes.append(.alignToSheet(fileOffset: sampleAtSheetStart / tcInfo.sampleRate))
                            }
                        }
                        add(.warning, .startMismatch, "\(name) needs a look",
                            "Its timecode file \(where_) \(atStart), \(amount) \(direction) the sheet (\(song.start)). It plays fine; the console would see it \(amount) \(delta > 0 ? "late" : "early").",
                            fixes)
                    }
                }
                if let jump = a.jumps.first {
                    let n = a.jumps.count
                    add(.warning, .timecodeJump, "\(name): timecode jumps",
                        "The timecode jumps \(n == 1 ? "once" : "\(n) times"), first at \(jump.expected) (it reads \(jump.found)).",
                        [.locate(seconds: Double(jump.sample) / tcInfo.sampleRate - song.fileOffset), .chooseTimecode])
                }
                if let gap = a.dropouts.first, let at = a.timecode(atSample: gap.lowerBound) {
                    let n = a.dropouts.count
                    add(.warning, .timecodeDropout, "\(name): timecode drops out",
                        "The timecode drops out \(n == 1 ? "once" : "\(n) times"), first around \(at).",
                        [.locate(seconds: Double(gap.lowerBound) / tcInfo.sampleRate - song.fileOffset), .chooseTimecode])
                }
            }
        }

        if let m = files.master, let t = files.timecode {
            let frame = 1.0 / song.rate.framesPerSecond
            let diff = m.duration - t.duration
            if song.hasTimecode && abs(diff) > frame {
                add(.warning, .lengthMismatch, "\(name): files are different lengths",
                    "The master is \(TimeFormat.clock(m.duration)) and the timecode file is \(TimeFormat.clock(t.duration)) (\(String(format: "%.2f", abs(diff))) s apart).")
            }
            if song.hasTimecode && m.sampleRate != t.sampleRate {
                add(.error, .sampleRateMismatch, "\(name): sample rates differ",
                    "The master is \(Int(m.sampleRate)) Hz and the timecode file is \(Int(t.sampleRate)) Hz. Export both at the same rate so they stay locked.")
            }
            if let device = deviceSampleRate, device != m.sampleRate {
                add(.warning, .deviceSampleRate, "\(name): converted for the interface",
                    "The files are \(Int(m.sampleRate)) Hz and the interface runs at \(Int(device)) Hz, so playback converts them. Setting the interface to \(Int(m.sampleRate)) Hz avoids that.",
                    [.audioOutput])
            }
        }
        return issues
    }

    /// Checks across songs: songs whose timecode ranges overlap, and duplicate starts.
    public static func validate(show: Show) -> [ShowIssue] {
        var issues: [ShowIssue] = []
        let sorted = show.songs.filter(\.hasTimecode).sorted { $0.start.seconds < $1.start.seconds }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            if a.start.seconds == b.start.seconds {
                issues.append(ShowIssue(severity: .warning, kind: .duplicateStart, songID: b.id, title: "\(a.title) and \(b.title) start at the same timecode",
                                        message: "Both start at \(a.start). The console can't tell them apart."))
            } else if let end = a.end, end.seconds > b.start.seconds {
                issues.append(ShowIssue(severity: .warning, kind: .overlap, songID: b.id, title: "\(a.title) runs into \(b.title)",
                                        message: "\(a.title) ends at \(end), after \(b.title) starts at \(b.start)."))
            }
        }
        return issues
    }
}


/// Applies the fixes that change the show. Every change is one the person clicked.
public enum ShowFixer {
    /// Returns the song as it was before (for undo), or nil if nothing changed.
    @discardableResult
    public static func apply(_ fix: IssueFix, songID: UUID, to show: inout Show) -> Song? {
        guard let i = show.songs.firstIndex(where: { $0.id == songID }) else { return nil }
        let before = show.songs[i]
        switch fix {
        case .useFileStart(let tc):
            // Markers keep their place in the song: they move with the start.
            let shift = tc.frames(since: Timecode(before.start.description, rate: tc.rate) ?? Timecode(seconds: before.start.seconds, rate: tc.rate))
            show.songs[i].start = tc
            show.songs[i].markers = before.markers.map { m in
                var m = m
                let t = Timecode(m.time.description, rate: tc.rate) ?? Timecode(seconds: m.time.seconds, rate: tc.rate)
                m.time = t.adding(frames: shift)
                return m
            }
        case .alignToSheet(let offset):
            show.songs[i].fileOffset = max(0, offset)
        case .useFileRate(let rate):
            func convert(_ t: Timecode) -> Timecode { Timecode(t.description, rate: rate) ?? Timecode(seconds: t.seconds, rate: rate) }
            show.songs[i].start = convert(before.start)
            show.songs[i].markers = before.markers.map { m in var m = m; m.time = convert(m.time); return m }
        case .chooseMaster, .chooseTimecode, .locate, .audioOutput:
            return nil
        }
        return show.songs[i] == before ? nil : before
    }

    /// Puts a song back as it was.
    public static func undo(_ song: Song, in show: inout Show) {
        guard let i = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
        show.songs[i] = song
    }
}
