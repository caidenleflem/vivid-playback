import Foundation

/// A hit sheet: every trigger and marker in a song, in time order, as a list to print or hand to
/// a programmer. Timecode, song time, bar and beat (once the song has a grid), the lane, what it
/// fires and the command the desk gets.
public enum HitSheet {
    public struct Row: Hashable, Sendable {
        public var timecode: String
        /// "1:02.73" from the song's start ("-0:00.40" before it).
        public var songTime: String
        /// "12.3" (bar 12, beat 3) when the song has a beat grid.
        public var barBeat: String?
        /// The lane's title; empty for a plain marker.
        public var lane: String
        /// "3.201" or "Seq DIVA DROP"; empty for a plain marker.
        public var whereText: String
        /// "Go+", "Goto cue 5", "Fader 80%", "Flash Off"; "Marker" for a plain marker.
        public var does: String
        /// The command line the desk gets ("Go+ Page 3.201"); empty for markers and fader levels.
        public var command: String
        /// The trigger's or marker's name.
        public var name: String
        /// On a muted lane: listed, but it doesn't fire.
        public var muted: Bool
        public var isMarker: Bool { lane.isEmpty }
    }

    public static func rows(for song: Song) -> [Row] {
        let fps = song.rate.framesPerSecond
        var lanes: [UUID: TriggerLane] = [:]
        for l in song.triggerLanes ?? [] { lanes[l.id] = l }
        let sorted = song.markers.enumerated().sorted {
            let a = $0.element.time.frames(since: song.start), b = $1.element.time.frames(since: song.start)
            return a != b ? a < b : $0.offset < $1.offset
        }
        return sorted.map { _, m in
            let t = Double(m.time.frames(since: song.start)) / fps
            let beat = song.beatGrid.map { g -> String in
                let bb = g.barBeat(at: t)
                return "\(bb.bar).\(bb.beat)"
            }
            guard let id = m.laneID, let lane = lanes[id] else {
                return Row(timecode: m.time.description, songTime: songTime(t), barBeat: beat, lane: "",
                           whereText: "", does: "Marker", command: "", name: m.label, muted: false)
            }
            return Row(timecode: m.time.description, songTime: songTime(t), barBeat: beat, lane: lane.title,
                       whereText: lane.whereText, does: does(m, lane: lane),
                       command: lane.commandLine(for: m) ?? "", name: m.label, muted: lane.muted)
        }
    }

    /// What a trigger does, in the desk's words.
    static func does(_ m: Marker, lane: TriggerLane) -> String {
        let act = m.action ?? lane.action
        let own = m.action != nil ? m.command : nil
        switch act {
        case .gotoCue:
            return m.value.map { "Goto cue \(TriggerLane.cueText($0))" } ?? "Goto cue ?"
        case .fader:
            return "Fader \(Int(max(0, min(100, (m.value ?? 100).rounded()))))%"
        case .command:
            let word = (own ?? lane.command ?? "").trimmingCharacters(in: .whitespaces)
            return word.isEmpty ? "Desk command" : word
        case .custom:
            return "Custom"
        default:
            return act.keyword ?? act.label
        }
    }

    /// "1:02.73", "12:00.00", "-0:00.40".
    public static func songTime(_ seconds: Double) -> String {
        let cs = Int((abs(seconds) * 100).rounded())
        let m = cs / 6000, s = (cs / 100) % 60, c = cs % 100
        return (seconds < 0 && cs > 0 ? "-" : "") + "\(m):" + (s < 10 ? "0" : "") + "\(s)." + (c < 10 ? "0" : "") + "\(c)"
    }

    // MARK: CSV

    public static let csvHeader = ["Song", "Timecode", "Song time", "Bar.Beat", "Lane", "Where", "Does", "Command", "Name", "Muted"]

    /// One table for one or more songs, for a spreadsheet.
    public static func csv(_ songs: [Song]) -> String {
        var lines = [csvHeader.map(csvField).joined(separator: ",")]
        for song in songs {
            let title = song.number.map { "\($0). \(song.title)" } ?? song.title
            for r in rows(for: song) {
                lines.append([title, r.timecode, r.songTime, r.barBeat ?? "", r.lane, r.whereText, r.does,
                              r.command, r.name, r.muted ? "muted" : ""].map(csvField).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func csvField(_ s: String) -> String {
        // A leading = + or @ is read as a formula by a spreadsheet: a ' first keeps it as text.
        var v = s
        if let f = v.first, "=+@".contains(f) { v = "'" + v }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Printable page

    /// A plain page to print (black on white): a heading per song, one table each.
    public static func html(_ songs: [Song], showName: String) -> String {
        var out = """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: 9.5pt; color: #000; }
        h1 { font-size: 15pt; margin: 0 0 2pt 0; }
        h2 { font-size: 12pt; margin: 14pt 0 3pt 0; }
        .sub { color: #555; font-size: 9pt; margin-bottom: 4pt; }
        table { border-collapse: collapse; width: 100%; }
        th { text-align: left; font-size: 8.5pt; color: #444; border-bottom: 1px solid #888; padding: 2pt 5pt; }
        td { padding: 2pt 5pt; border-bottom: 1px solid #ddd; vertical-align: top; }
        .tc { font-family: Menlo, monospace; white-space: nowrap; }
        .marker td { font-weight: bold; background: #f1f1f1; }
        .muted td { color: #999; }
        </style></head><body>
        <h1>\(escape(showName)) · Hit sheet</h1>

        """
        for song in songs {
            let rows = rows(for: song)
            let title = song.number.map { "\($0). \(song.title)" } ?? song.title
            let triggers = rows.filter { !$0.isMarker }.count
            var sub = "Starts \(song.start.description) · \(triggers) trigger\(triggers == 1 ? "" : "s")"
            if let g = song.beatGrid { sub += " · \(g.tempoText)" }
            out += "<h2>\(escape(title))</h2><div class=\"sub\">\(escape(sub))</div>\n"
            guard !rows.isEmpty else { out += "<div class=\"sub\">Nothing on this song yet.</div>\n"; continue }
            let beats = song.beatGrid != nil
            out += "<table><tr><th>Timecode</th><th>Time</th>" + (beats ? "<th>Bar</th>" : "")
                + "<th>Lane</th><th>Where</th><th>Does</th><th>Name</th></tr>\n"
            for r in rows {
                let cls = r.isMarker ? " class=\"marker\"" : (r.muted ? " class=\"muted\"" : "")
                let does = r.does + (r.muted ? " (muted)" : "")
                out += "<tr\(cls)><td class=\"tc\">\(escape(r.timecode))</td><td class=\"tc\">\(escape(r.songTime))</td>"
                    + (beats ? "<td class=\"tc\">\(escape(r.barBeat ?? ""))</td>" : "")
                    + "<td>\(escape(r.lane))</td><td>\(escape(r.whereText))</td><td>\(escape(does))</td>"
                    + "<td>\(escape(r.name))</td></tr>\n"
            }
            out += "</table>\n"
        }
        return out + "</body></html>\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
