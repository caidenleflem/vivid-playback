import Foundation

/// A lighting console that receives OSC (grandMA3: Menu › In & Out › OSC, with Receive and
/// Receive Command on, and the same prefix).
public struct ConsoleTarget: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var prefix: String
    public var enabled: Bool
    /// The network port (its system name, "en7") the commands go out on; nil lets macOS choose.
    public var networkPort: String?

    public init(id: UUID = UUID(), name: String = "grandMA3", host: String = "", port: UInt16 = 8000,
                prefix: String = "gma3", enabled: Bool = true, networkPort: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.prefix = prefix
        self.enabled = enabled
        self.networkPort = networkPort
    }

    /// "/gma3" (or "" with no prefix).
    var root: String {
        let p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return p.isEmpty ? "" : "/\(p)"
    }

    /// A command line for this console: "/gma3/cmd" with the text.
    public func command(_ text: String) -> OSCMessage { OSCMessage("\(root)/cmd", [.string(text)]) }
}

public enum LaneAction: String, Codable, CaseIterable, Sendable {
    case goPlus, goMinus, top, on, off, gotoCue, fader, custom

    public var label: String {
        switch self {
        case .goPlus: return "Go+"
        case .goMinus: return "Go−"
        case .top: return "Top"
        case .on: return "On"
        case .off: return "Off"
        case .gotoCue: return "Goto cue"
        case .fader: return "Fader level"
        case .custom: return "Custom command"
        }
    }
}

/// One executor, fired by the triggers on its lane.
public struct TriggerLane: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var page: Int
    public var executor: Int
    public var action: LaneAction
    /// For `.custom`: the command line, with {page}, {exec}, {value} and {label}.
    public var command: String?
    /// Which consoles; empty means every enabled console.
    public var consoleIDs: [UUID]
    public var color: Int
    public var muted: Bool
    /// The key that drops a trigger on this lane at the playhead (one lowercase character).
    public var key: String?

    public init(id: UUID = UUID(), name: String = "", page: Int = 1, executor: Int = 201, action: LaneAction = .goPlus,
                command: String? = nil, consoleIDs: [UUID] = [], color: Int = 0, muted: Bool = false, key: String? = nil) {
        self.id = id
        self.name = name
        self.page = page
        self.executor = executor
        self.action = action
        self.command = command
        self.consoleIDs = consoleIDs
        self.color = color
        self.muted = muted
        self.key = key.flatMap(TriggerLane.normalizedKey)
    }

    /// Keys the timeline already uses: Space, M (marker), L (loop), C (trigger on the chosen lane).
    public static let reservedKeys: Set<String> = [" ", "m", "l", "c"]
    /// Keys handed to new lanes, in order.
    public static let keyOrder = Array("1234567890qwertyuiopasdfghjkzxvbn").map(String.init)

    /// One letter, digit or symbol, lowercased; nil for anything else or a reserved key.
    public static func normalizedKey(_ text: String) -> String? {
        let t = text.lowercased()
        guard t.count == 1, let c = t.first, !c.isWhitespace, !c.isNewline,
              c.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0xF700 }),
              !reservedKeys.contains(t) else { return nil }
        return t
    }

    /// The same lane with a new identity (for copying lanes to another song).
    public func copy() -> TriggerLane {
        var l = self
        l.id = UUID()
        return l
    }

    /// The first key no lane uses yet.
    public static func freeKey(in lanes: [TriggerLane]) -> String? {
        let used = Set(lanes.compactMap(\.key))
        return keyOrder.first { !used.contains($0) }
    }

    /// "1.201 · Go+", or the lane's own name.
    public var title: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "\(page).\(executor) · \(action.label)" : n
    }

    /// The command line this lane sends for a trigger (nil for fader lanes, which send a level).
    public func commandLine(for marker: Marker? = nil) -> String? {
        // grandMA3 addresses an executor by its page: "Go+ Page 3.201".
        let target = "Page \(page).\(executor)"
        switch marker?.action ?? action {
        case .goPlus: return "Go+ \(target)"
        case .goMinus: return "Go- \(target)"
        case .top: return "Top \(target)"
        case .on: return "On \(target)"
        case .off: return "Off \(target)"
        case .gotoCue:
            guard let cue = marker?.value else { return nil }
            return "Goto Cue \(Self.cueText(cue)) \(target)"
        case .fader: return nil
        case .custom:
            let value = marker?.value.map { String(Int($0.rounded())) } ?? ""
            return (command ?? "")
                .replacingOccurrences(of: "{page}", with: String(page))
                .replacingOccurrences(of: "{exec}", with: String(executor))
                .replacingOccurrences(of: "{value}", with: value)
                .replacingOccurrences(of: "{label}", with: marker?.label ?? "")
        }
    }

    /// The OSC messages a trigger sends to one console.
    /// "5", "5.5": a cue number as the desk writes it.
    public static func cueText(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%g", n)
    }

    public func messages(for marker: Marker?, console: ConsoleTarget) -> [OSCMessage] {
        if (marker?.action ?? action) == .fader {
            let level = Int32(max(0, min(100, (marker?.value ?? 100).rounded())))
            return [OSCMessage("\(console.root)/Page\(page)/Fader\(executor)", [.int(level)])]
        }
        guard let cmd = commandLine(for: marker), !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return [OSCMessage("\(console.root)/cmd", [.string(cmd)])]
    }

    /// The consoles this lane sends to.
    public func targets(in consoles: [ConsoleTarget]) -> [ConsoleTarget] {
        consoles.filter { $0.enabled && !$0.host.isEmpty && (consoleIDs.isEmpty || consoleIDs.contains($0.id)) }
    }
}

/// Decides which triggers fire as the playhead moves: those whose frame was crossed while
/// running forward. A jump (a locate, a loop back, a song change) arms from the new spot
/// without firing what was skipped.
public struct TriggerScheduler: Sendable {
    public struct Trigger: Hashable, Sendable {
        public var frame: Int     // show timecode, as a frame count
        public var id: UUID
        public init(frame: Int, id: UUID) {
            self.frame = frame
            self.id = id
        }
    }

    private var last: Int?
    /// Frames the playhead may advance between two checks and still count as playing through.
    public var maxStep = 8

    public init() {}

    public mutating func reset() { last = nil }

    /// `frame` is the frame playing now (already moved earlier by any fire-early offset).
    public mutating func advance(to frame: Int, running: Bool, triggers: [Trigger]) -> [UUID] {
        defer { last = running ? frame : nil }
        guard running, let last else { return [] }
        let step = frame - last
        guard step > 0, step <= maxStep else { return [] }
        return triggers.filter { $0.frame > last && $0.frame <= frame }.sorted { $0.frame < $1.frame }.map(\.id)
    }
}

/// One executor to label on the console: the lane name it gets, the other names lanes gave it
/// (when songs disagree), and which consoles it goes to.
public struct ExecutorLabel: Equatable, Identifiable, Sendable {
    public var page: Int
    public var executor: Int
    /// Every name lanes give this executor, most used first.
    public var names: [String]
    /// The name to send (the most used, unless changed).
    public var name: String
    /// Consoles the lanes send to; empty means every enabled console.
    public var consoleIDs: [UUID]
    /// How many lanes (across the songs) use this executor.
    public var laneCount: Int

    public var id: String { "\(page).\(executor)" }
    public var hasConflict: Bool { names.count > 1 }

    /// The executor's lanes, for working out its consoles.
    public func targets(in consoles: [ConsoleTarget]) -> [ConsoleTarget] {
        consoles.filter { $0.enabled && !$0.host.isEmpty && (consoleIDs.isEmpty || consoleIDs.contains($0.id)) }
    }

    /// The command line, from a template with {page}, {exec} and {name}. Double quotes in the
    /// name become single ones so the console's command line stays intact.
    public func command(template: String) -> String {
        let safe = name.replacingOccurrences(of: "\"", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        return template
            .replacingOccurrences(of: "{page}", with: String(page))
            .replacingOccurrences(of: "{exec}", with: String(executor))
            .replacingOccurrences(of: "{name}", with: safe)
    }

    public static let defaultTemplate = "Label Page {page}.{exec} \"{name}\""
    /// The default before executors were addressed by page (settings saved with it move on).
    public static let oldDefaultTemplate = "Label Exec {page}.{exec} \"{name}\""

    /// One label per executor from the lanes of a set of songs. Lanes without a name of their
    /// own are left out (nothing to send). Executors in page/executor order.
    public static func plan(lanes: [TriggerLane]) -> [ExecutorLabel] {
        var order: [String] = []
        var byExec: [String: (page: Int, exec: Int, counts: [String: Int], firstSeen: [String], consoles: Set<UUID>, all: Bool, lanes: Int)] = [:]
        for lane in lanes {
            let name = lane.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = "\(lane.page).\(lane.executor)"
            var e = byExec[key] ?? (lane.page, lane.executor, [:], [], [], false, 0)
            if byExec[key] == nil { order.append(key) }
            if e.counts[name] == nil { e.firstSeen.append(name) }
            e.counts[name, default: 0] += 1
            if lane.consoleIDs.isEmpty { e.all = true } else { e.consoles.formUnion(lane.consoleIDs) }
            e.lanes += 1
            byExec[key] = e
        }
        return order.compactMap { key -> ExecutorLabel? in
            guard let e = byExec[key] else { return nil }
            let names = e.firstSeen.enumerated().sorted { a, b in
                let ca = e.counts[a.element] ?? 0, cb = e.counts[b.element] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }.map(\.element)
            return ExecutorLabel(page: e.page, executor: e.exec, names: names, name: names[0],
                                 consoleIDs: e.all ? [] : e.consoles.sorted { $0.uuidString < $1.uuidString }, laneCount: e.lanes)
        }
        .sorted { ($0.page, $0.executor) < ($1.page, $1.executor) }
    }
}
