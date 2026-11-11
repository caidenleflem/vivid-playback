import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A grandMA3 timecode show, read from its exported XML: where it starts (its offset), and per
/// track the sequence it fires and its events (time, what it does, the cue it goes to).
public struct MA3Timecode: Equatable, Sendable {
    public struct Event: Equatable, Sendable {
        /// Seconds from the start of the timecode show.
        public var time: Double
        /// What it does. Any desk word Vivid has no name for comes through as `.command` with the
        /// word itself, so nothing is dropped. Nil only for an event with no word at all.
        public var action: LaneAction?
        /// For `.command`: the desk's word(s) ("Flash Off").
        public var word: String?
        /// The desk's word for it ("Go+", "Off", "Flash"…).
        public var token: String
        /// The cue's name ("BEAT DROP") and number, when the event goes to one.
        public var cueName: String?
        public var cueNumber: Double?
    }

    public struct Track: Equatable, Sendable {
        public var name: String?
        /// The sequence fired: its name, or its number as text.
        public var sequence: String
        public var events: [Event]
    }

    public var name: String
    /// The timecode the show starts at, in seconds (its "Offset TC Slot").
    public var offset: Double
    public var duration: Double?
    public var tracks: [Track]
    /// Tracks that fire something other than a sequence (left out, and counted).
    public var otherTracks: Int

    /// Every timecode show in an exported XML file.
    public static func parse(_ data: Data) -> [MA3Timecode] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        _ = parser.parse()
        return reader.shows
    }

    /// "1h50m00.00", "3m43.33", "4.800", "1m02.733" → seconds. Nil for anything else ("To End").
    public static func seconds(_ text: String) -> Double? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces).lowercased())
        guard !rest.isEmpty else { return nil }
        var total = 0.0
        if let h = rest.firstIndex(of: "h") {
            guard let v = Double(rest[..<h]) else { return nil }
            total += v * 3600
            rest = rest[rest.index(after: h)...]
        }
        if let m = rest.firstIndex(of: "m") {
            guard let v = Double(rest[..<m]) else { return nil }
            total += v * 60
            rest = rest[rest.index(after: m)...]
        }
        if rest.hasSuffix("s") { rest = rest.dropLast() }
        if !rest.isEmpty {
            guard let v = Double(rest) else { return nil }
            total += v
        }
        return total
    }

    /// The desk's word as a lane action: one Vivid knows by name, or `.command` with the word.
    /// `released`: a Flash, Temp or Swap key let go (the desk records the press and the release).
    public static func action(_ token: String, released: Bool = false) -> (action: LaneAction, word: String?)? {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let momentary = ["flash", "temp", "swap"].contains(t.lowercased())
        if released && momentary { return (.command, "\(t) Off") }
        if let a = LaneAction.fromKeyword(t) { return (a, nil) }
        return (.command, t)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var shows: [MA3Timecode] = []
        private var show: MA3Timecode?
        private var track: Track?
        private var trackIsOther = false
        private var event: Event?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "Timecode":
                show = MA3Timecode(name: a["Name"] ?? "Timecode", offset: a["OffsetTCSlot"].flatMap(MA3Timecode.seconds) ?? 0,
                                   duration: a["Duration"].flatMap(MA3Timecode.seconds), tracks: [], otherTracks: 0)
            case "Track":
                let target = a["Target"] ?? ""
                if let r = target.range(of: ".Sequences.") {
                    let seq = String(target[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    track = Track(name: a["Name"].flatMap { $0.isEmpty ? nil : $0 }, sequence: seq, events: [])
                    trackIsOther = false
                } else {
                    track = nil
                    trackIsOther = true
                }
            case "CmdEvent":
                guard track != nil, let time = a["Time"].flatMap(MA3Timecode.seconds) else { event = nil; return }
                let token = a["Name"] ?? ""
                let mapped = MA3Timecode.action(token)
                event = Event(time: time, action: mapped?.action, word: mapped?.word, token: token,
                              cueName: a["CueDestination"].flatMap { $0.isEmpty ? nil : $0 }, cueNumber: nil)
            case "RealtimeCmd":
                guard event != nil else { return }
                let token = a["ExecToken"].flatMap { $0.isEmpty ? nil : $0 } ?? event?.token ?? ""
                if let mapped = MA3Timecode.action(token, released: a["Status"]?.lowercased() == "off") {
                    event?.token = token
                    event?.action = mapped.action
                    event?.word = mapped.word
                }
                // "0.5.1395.2000": the last number is the cue, in thousandths.
                if let v = a["ValCueDestination"], let last = v.split(separator: ".").last, let n = Double(last), n > 0 {
                    event?.cueNumber = n / 1000
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "CmdEvent":
                if let e = event { track?.events.append(e) }
                event = nil
            case "Track":
                if let t = track, !t.events.isEmpty { show?.tracks.append(t) }
                if trackIsOther { show?.otherTracks += 1 }
                track = nil
                trackIsOther = false
            case "Timecode":
                if let s = show { shows.append(s) }
                show = nil
            default:
                break
            }
        }
    }
}

/// Putting a grandMA3 timecode show onto a song: one lane per track (firing its sequence), one
/// trigger per event, placed by timecode.
public enum MA3TimecodeImport {
    public enum Match: Equatable, Sendable { case name, timecode, selected }

    /// The song a timecode show belongs to: the one with its name, else the one its start falls
    /// in, else the selected song.
    public static func song(for tc: MA3Timecode, in songs: [Song], selected: UUID?) -> (id: UUID, match: Match)? {
        let wanted = tc.name.trimmingCharacters(in: .whitespaces)
        if let s = songs.first(where: { $0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame }) {
            return (s.id, .name)
        }
        if let s = songs.first(where: { s in
            guard s.hasTimecode else { return false }
            let from = s.start.seconds - s.fileOffset
            return tc.offset >= from - 0.5 && tc.offset <= s.start.seconds + max(1, s.playLength ?? 1)
        }) {
            return (s.id, .timecode)
        }
        return selected.map { ($0, .selected) }
    }

    public struct Result: Equatable, Sendable {
        public var lanesAdded = 0
        public var lanesReused = 0
        public var triggers = 0
        /// Imported before (whether the trigger is still there, moved or deleted).
        public var alreadyImported = 0
        /// Before the song's pre-roll or after its end.
        public var outside = 0
        /// Events with no word at all.
        public var unreadable = 0
        /// How far the show's start is from the song's (seconds; the show's minus the song's).
        public var startDifference: Double = 0
    }

    /// The identity of a desk event: its sequence, its timecode to the millisecond, and its word.
    public static func key(_ e: MA3Timecode.Event, track: MA3Timecode.Track, offset: Double) -> String {
        "\(track.sequence.lowercased())|\(Int(((offset + e.time) * 1000).rounded()))|\(e.token.lowercased())|\((e.word ?? "").lowercased())"
    }

    /// Adds the show to `song`, bringing in only events not imported before. Lanes for the same
    /// sequence are reused (one is made only when a track has something new).
    public static func apply(_ tc: MA3Timecode, to song: inout Song) -> Result {
        var r = Result()
        r.startDifference = tc.offset - song.start.seconds
        var lanes = song.triggerLanes ?? []
        var imported = Set(song.importedDeskEvents ?? [])
        let fps = song.rate.framesPerSecond
        let minFrame = -Int((song.fileOffset * fps).rounded(.up))
        let maxFrame = song.playLength.map { Int(($0 * fps).rounded(.up)) }
        for (n, track) in tc.tracks.enumerated() {
            // The lane does what most of the track does; the rest carry their own action.
            let counts = Dictionary(track.events.compactMap(\.action).map { ($0, 1) }, uniquingKeysWith: +)
            let main = counts.filter { $0.key != .gotoCue && $0.key != .command }
                .max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key ?? .goPlus
            var laneIndex = lanes.firstIndex { $0.sequence?.caseInsensitiveCompare(track.sequence) == .orderedSame }
            let existed = laneIndex != nil
            let before = r.triggers
            defer { if existed && r.triggers > before { r.lanesReused += 1 } }
            for e in track.events {
                guard let action = e.action else { r.unreadable += 1; continue }
                let k = key(e, track: track, offset: tc.offset)
                if imported.contains(k) { r.alreadyImported += 1; continue }
                // The desk keeps milliseconds: the nearest frame (1:02.733 is frame 22 at 30 fps).
                let tcode = Timecode(frameCount: Int(((tc.offset + e.time) * fps).rounded()), rate: song.rate)
                let frame = tcode.frames(since: song.start)
                if frame < minFrame || maxFrame.map({ frame > $0 }) == true { r.outside += 1; continue }
                if laneIndex == nil {
                    let name = track.name ?? (Int(track.sequence) != nil ? "Sequence \(track.sequence)" : track.sequence)
                    lanes.append(TriggerLane(name: name, page: 0, executor: 0, action: main,
                                             color: (lanes.count + n) % 6, sequence: track.sequence))
                    laneIndex = lanes.count - 1
                    r.lanesAdded += 1
                }
                guard let li = laneIndex else { continue }
                let lane = lanes[li]
                imported.insert(k)
                // Already there from before this was remembered (same lane, frame and action).
                if song.markers.contains(where: { $0.laneID == lane.id && abs($0.time.frames(since: song.start) - frame) <= 1
                                                  && ($0.action ?? lane.action) == action && $0.command == e.word }) {
                    r.alreadyImported += 1
                    continue
                }
                let label: String
                switch action {
                case .off: label = "Off"
                case .command: label = e.word ?? e.token
                default: label = e.cueName ?? e.cueNumber.map { "Cue \(TriggerLane.cueText($0))" } ?? action.label
                }
                let own = action == lane.action && action != .command ? nil : action
                song.markers.append(Marker(time: tcode, label: label, laneID: lane.id,
                                           value: action == .gotoCue ? e.cueNumber : nil, action: own,
                                           command: own == .command ? e.word : nil))
                r.triggers += 1
            }
        }
        song.triggerLanes = lanes.isEmpty ? nil : lanes
        song.importedDeskEvents = imported.isEmpty ? nil : imported.sorted()
        song.markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
        return r
    }
}
