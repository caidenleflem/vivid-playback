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

    public init(id: UUID = UUID(), name: String = "grandMA3", host: String = "", port: UInt16 = 8000,
                prefix: String = "gma3", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.prefix = prefix
        self.enabled = enabled
    }

    /// "/gma3" (or "" with no prefix).
    var root: String {
        let p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return p.isEmpty ? "" : "/\(p)"
    }
}

public enum LaneAction: String, Codable, CaseIterable, Sendable {
    case goPlus, goMinus, top, on, off, fader, custom

    public var label: String {
        switch self {
        case .goPlus: return "Go+"
        case .goMinus: return "Go−"
        case .top: return "Top"
        case .on: return "On"
        case .off: return "Off"
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
        let target = "Exec \(page).\(executor)"
        switch action {
        case .goPlus: return "Go+ \(target)"
        case .goMinus: return "Go- \(target)"
        case .top: return "Top \(target)"
        case .on: return "On \(target)"
        case .off: return "Off \(target)"
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
    public func messages(for marker: Marker?, console: ConsoleTarget) -> [OSCMessage] {
        if action == .fader {
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
