import Foundation

public struct Marker: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var time: Timecode
    public var label: String
    /// The executor lane this is a trigger on; nil for a plain marker.
    public var laneID: UUID?
    /// For fader lanes: the level to set, 0–100.
    public var value: Double?

    public init(id: UUID = UUID(), time: Timecode, label: String, laneID: UUID? = nil, value: Double? = nil) {
        self.id = id
        self.time = time
        self.label = label
        self.laneID = laneID
        self.value = value
    }
}

public struct Song: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var number: Int?
    public var title: String
    /// The timecode the console sees when the song starts.
    public var start: Timecode
    /// Where `start` falls in the audio files, in seconds (pre-roll before the song).
    public var fileOffset: Double
    /// Length of the song from `start`, in seconds, once known.
    public var length: Double?
    /// Paths relative to the show's media folder (or absolute, for files elsewhere).
    public var masterPath: String?
    public var timecodePath: String?
    /// Which channel of the timecode file holds the LTC (0-based), as found on import.
    public var timecodeFileChannel: Int?
    /// True for songs the sheet lists with no timecode (a looped bed, an interstitial):
    /// they play, but send no timecode. `start` is then only a placeholder.
    public var timecodeOff: Bool?
    /// The act or section from the sheet ("Act 1", "Encore").
    public var part: String?
    public var notes: String?
    public var markers: [Marker]
    /// This song's executor lanes: each fires one MA3 executor from the triggers on it.
    public var triggerLanes: [TriggerLane]? = nil
    /// How long the song's audio actually is, in seconds of file (the longer of the master and
    /// the timecode file), measured each time the files are checked. Nil with no audio.
    public var audioLength: Double? = nil

    /// How long the song plays, from its start: the audio's own length once it has audio (longer
    /// or shorter than the sheet said), the sheet's length until then. The sheet is a starting
    /// point, not an end point.
    public var playLength: Double? {
        if let audio = audioLength, audio > 0 { return max(0, audio - fileOffset) }
        return length
    }

    public init(id: UUID = UUID(), number: Int? = nil, title: String, start: Timecode, fileOffset: Double = 0,
                length: Double? = nil, masterPath: String? = nil, timecodePath: String? = nil,
                timecodeFileChannel: Int? = nil, notes: String? = nil, markers: [Marker] = []) {
        self.id = id
        self.number = number
        self.title = title
        self.start = start
        self.fileOffset = fileOffset
        self.length = length
        self.masterPath = masterPath
        self.timecodePath = timecodePath
        self.timecodeFileChannel = timecodeFileChannel
        self.notes = notes
        self.markers = markers
    }

    public var rate: FrameRate { start.rate }
    public var hasTimecode: Bool { timecodeOff != true }

    public var end: Timecode? {
        guard let length else { return nil }
        return start.adding(frames: Int((length * rate.framesPerSecond).rounded(.down)))
    }
}

public struct Setlist: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var songIDs: [UUID]
    /// Cover image, relative to the show package.
    public var artwork: String?
    /// Songs kept in the list but skipped tonight.
    public var skipped: Set<UUID>

    public init(id: UUID = UUID(), name: String, songIDs: [UUID], skipped: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.songIDs = songIDs
        self.skipped = skipped
    }
}

public struct OutputRouting: Codable, Hashable, Sendable {
    /// Core Audio device UID; nil means the system default output.
    public var deviceUID: String?
    /// 1-based output channels for the master (usually a pair).
    public var masterChannels: [Int]
    /// 1-based output channel for timecode; nil until chosen. On `timecodeDeviceUID` when set.
    public var timecodeChannel: Int?
    /// The interface timecode goes out on, when it isn't the master's; nil means the master's.
    public var timecodeDeviceUID: String?
    public var masterGainDB: Double
    /// Fixed timecode level; the master volume never changes it.
    public var timecodeGainDB: Double

    public init(deviceUID: String? = nil, masterChannels: [Int] = [1, 2], timecodeChannel: Int? = nil,
                timecodeDeviceUID: String? = nil, masterGainDB: Double = 0, timecodeGainDB: Double = -6) {
        self.deviceUID = deviceUID
        self.masterChannels = masterChannels
        self.timecodeChannel = timecodeChannel
        self.timecodeDeviceUID = timecodeDeviceUID
        self.masterGainDB = masterGainDB
        self.timecodeGainDB = timecodeGainDB
    }
}

extension OutputRouting {
    /// Master and timecode go out on two different interfaces.
    public var splitsInterfaces: Bool { timecodeDeviceUID != nil && timecodeDeviceUID != deviceUID }
}

public struct Show: Codable, Hashable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var name: String
    /// Who the show is for; shows are grouped by artist on the Albums page.
    public var artist: String?
    public var defaultRate: FrameRate
    /// The folder the media was imported from; song paths are relative to it. Relinking a show
    /// that moved is a matter of changing this.
    public var mediaFolder: String?
    public var songs: [Song]
    public var setlists: [Setlist]
    public var routing: OutputRouting
    public var sheetMapping: ColumnMapping?
    public var sheetFile: String?
    /// Keys of warnings Caiden hid (`ShowIssue.key`).
    public var dismissedIssues: [String]?
    /// Executor lanes from shows saved before lanes belonged to songs. Read once and moved onto
    /// the songs by `moveLanesToSongs()`; new shows leave it empty.
    public var triggerLanes: [TriggerLane]?

    /// Older shows kept one set of lanes for the whole show. Each song now has its own: a song
    /// gets the show lanes it has triggers on (same ids, so its triggers stay on them), and
    /// songs with none get none. Returns true when anything moved.
    @discardableResult
    public mutating func moveLanesToSongs() -> Bool {
        guard let shared = triggerLanes, !shared.isEmpty else {
            if triggerLanes != nil { triggerLanes = nil; return true }
            return false
        }
        for i in songs.indices {
            let used = Set(songs[i].markers.compactMap(\.laneID))
            let mine = songs[i].triggerLanes ?? []
            let have = Set(mine.map(\.id))
            let moved = shared.filter { used.contains($0.id) && !have.contains($0.id) }
            if !moved.isEmpty { songs[i].triggerLanes = mine + moved }
        }
        triggerLanes = nil
        return true
    }

    public init(name: String, defaultRate: FrameRate = .fps30, mediaFolder: String? = nil, songs: [Song] = [],
                setlists: [Setlist] = [], routing: OutputRouting = OutputRouting(), sheetMapping: ColumnMapping? = nil,
                sheetFile: String? = nil) {
        self.format = Self.currentFormat
        self.name = name
        self.defaultRate = defaultRate
        self.mediaFolder = mediaFolder
        self.songs = songs
        self.setlists = setlists
        self.routing = routing
        self.sheetMapping = sheetMapping
        self.sheetFile = sheetFile
    }

    public func url(forMediaPath path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let mediaFolder else { return nil }
        return URL(fileURLWithPath: mediaFolder).appendingPathComponent(path)
    }

    public func song(id: UUID) -> Song? { songs.first { $0.id == id } }

    public func isDismissed(_ issue: ShowIssue) -> Bool {
        issue.canDismiss && (dismissedIssues ?? []).contains(issue.key)
    }

    public mutating func dismiss(_ issue: ShowIssue) {
        guard issue.canDismiss, !isDismissed(issue) else { return }
        dismissedIssues = (dismissedIssues ?? []) + [issue.key]
    }

    public mutating func restore(_ issue: ShowIssue) {
        dismissedIssues?.removeAll { $0 == issue.key }
    }

    /// Forgets hidden findings that no longer exist, so the list doesn't grow forever.
    public mutating func pruneDismissed(keeping current: [ShowIssue]) {
        guard let d = dismissedIssues else { return }
        let live = Set(current.map(\.key))
        dismissedIssues = d.filter(live.contains)
    }
}

/// Saves and opens `.vividshow` packages: a folder holding `show.json`.
public enum ShowStore {
    public static let fileExtension = "vividshow"

    public static func save(_ show: Show, to package: URL) throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(show).write(to: package.appendingPathComponent("show.json"), options: .atomic)
    }

    public static func load(from package: URL) throws -> Show {
        let data = try Data(contentsOf: package.appendingPathComponent("show.json"))
        var show = try JSONDecoder().decode(Show.self, from: data)
        show.moveLanesToSongs()
        return show
    }

    /// `path` relative to `folder` when it's inside it, else absolute.
    public static func relativePath(of url: URL, in folder: URL) -> String {
        let f = folder.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        let prefix = f.hasSuffix("/") ? f : f + "/"
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
    }
}

/// Converts between show timecode and positions in a song's audio files.
public enum PlaybackMath {
    /// Seconds into the audio files where `tc` plays.
    public static func fileTime(for tc: Timecode, in song: Song) -> Double {
        song.fileOffset + Double(tc.frames(since: song.start)) / song.rate.framesPerSecond
    }

    /// The timecode playing `seconds` into the audio files.
    public static func timecode(atFileTime seconds: Double, in song: Song) -> Timecode {
        let frames = Int(((seconds - song.fileOffset) * song.rate.framesPerSecond + 1e-6).rounded(.down))
        return song.start.adding(frames: frames)
    }

    public static func sampleFrame(for tc: Timecode, in song: Song, sampleRate: Double) -> Int64 {
        Int64((fileTime(for: tc, in: song) * sampleRate).rounded())
    }
}
