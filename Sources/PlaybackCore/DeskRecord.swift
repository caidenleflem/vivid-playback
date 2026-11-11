import Foundation

/// A GO from the lighting desk, for recording triggers onto lanes: which executor went (and on
/// which page, when the desk says), and the cue when it's known.
public struct DeskGo: Equatable, Sendable {
    public enum Source: String, Sendable { case osc = "OSC", msc = "MSC" }
    public var page: Int?
    public var executor: Int
    public var cue: String?
    public var source: Source

    public init(page: Int? = nil, executor: Int, cue: String? = nil, source: Source) {
        self.page = page
        self.executor = executor
        self.cue = cue
        self.source = source
    }

    /// "1.201", or "201" when no page came with it.
    public var label: String { page.map { "\($0).\(executor)" } ?? "\(executor)" }

    // MARK: OSC

    /// `/vivid/exec "1.201"`, `/vivid/exec 201`, `/vivid/exec 1 201` (page, executor), with an
    /// optional cue after: `/vivid/exec "1.201" "4"`. A 0 (a button released) is ignored.
    /// On a grandMA3: `SendOSC 1 "/vivid/exec,s,1.201"` in a macro or a cue's command.
    public static func from(_ m: OSCMessage) -> DeskGo? {
        guard m.vividCommand == "exec" else { return nil }
        let args = m.arguments
        guard let first = args.first else { return nil }
        if case .string(let text) = first {
            guard let ref = executorRef(text) else { return nil }
            return DeskGo(page: ref.page, executor: ref.executor, cue: args.dropFirst().first.map(\.text).flatMap(cueText),
                          source: .osc)
        }
        guard let a = first.number, a == a.rounded(), a > 0 else { return nil }
        if args.count >= 2, let b = args[1].number, b == b.rounded(), b > 0 {
            return DeskGo(page: Int(a), executor: Int(b), cue: args.dropFirst(2).first.map(\.text).flatMap(cueText), source: .osc)
        }
        return DeskGo(page: nil, executor: Int(a), source: .osc)
    }

    /// "1.201" → page 1, executor 201; "201" → executor 201.
    static func executorRef(_ text: String) -> (page: Int?, executor: Int)? {
        let bits = text.trimmingCharacters(in: .whitespaces).split(separator: ".").map(String.init)
        switch bits.count {
        case 1:
            guard let e = Int(bits[0]), e > 0 else { return nil }
            return (nil, e)
        case 2:
            guard let p = Int(bits[0]), let e = Int(bits[1]), p > 0, e > 0 else { return nil }
            return (p, e)
        default:
            return nil
        }
    }

    private static func cueText(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: MIDI Show Control

    /// A GO in MIDI Show Control, found anywhere in `bytes` (a MIDI message, or a UDP packet
    /// with a header in front, as desks send MSC over Ethernet):
    /// `F0 7F <device> 02 <format> 01 <cue> [00 <list> [00 <path>]] F7`.
    /// The cue list is read as the executor ("201", or "1.201" page and executor).
    public static func from(msc bytes: [UInt8]) -> DeskGo? {
        guard let start = indexOfMSC(in: bytes) else { return nil }
        guard let end = bytes[start...].firstIndex(of: 0xF7) else { return nil }
        let msg = Array(bytes[start...end])
        // F0 7F dev 02 fmt cmd data… F7
        guard msg.count >= 7, msg[5] == 0x01 else { return nil }   // 01 = GO
        let data = Array(msg[6..<(msg.count - 1)])
        let fields = data.split(separator: 0x00, omittingEmptySubsequences: false)
            .map { String(decoding: $0.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self) }
        let cue = fields.first.flatMap(cueText)
        guard fields.count >= 2, let ref = executorRef(fields[1]) else { return nil }
        return DeskGo(page: ref.page, executor: ref.executor, cue: cue, source: .msc)
    }

    private static func indexOfMSC(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 7 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 0xF0 && bytes[i + 1] == 0x7F && bytes[i + 3] == 0x02 {
            return i
        }
        return nil
    }
}

public enum DeskRecorder {
    /// The lane a GO lands on: the one firing that executor (on that page, when the desk said
    /// which). With "a.b" from MSC, both page.executor and executor.page are tried, since desks
    /// differ. Nil when no lane fires it yet.
    public static func lane(for go: DeskGo, in lanes: [TriggerLane]) -> TriggerLane? {
        if let page = go.page {
            if let l = lanes.first(where: { $0.page == page && $0.executor == go.executor }) { return l }
            if go.source == .msc, let l = lanes.first(where: { $0.page == go.executor && $0.executor == page }) { return l }
            return nil
        }
        return lanes.first { $0.executor == go.executor }
    }

    /// A GO within `tolerance` frames of a trigger the lane already has is the desk echoing a
    /// trigger this app just fired (or a double press), not a new one.
    public static func isDuplicate(frame: Int, existing: [Int], tolerance: Int = 8) -> Bool {
        existing.contains { abs($0 - frame) <= tolerance }
    }
}

/// What a sequence on the desk just did, sent by the Vivid Recorder plugin on the grandMA3:
/// `/vivid/seq "3.201" "on" "5" "4" "3" "on" "Chorus"`: the executor (page.executor), on or off,
/// the cue it's on now, that cue's place in the list (0 = the first cue), the place it was at
/// before, whether it was on before, and the cue's name. A "-" or -1 is "not known".
public struct DeskSequenceEvent: Equatable, Sendable {
    public var page: Int
    public var executor: Int
    public var isOn: Bool
    public var cue: Double?
    public var index: Int?
    public var previousIndex: Int?
    public var wasOn: Bool
    public var name: String?
    /// When the plugin saw the change, on the desk's own clock (seconds). Nil from an older
    /// plugin, or a desk whose clock it can't read.
    public var deskTime: Double?

    /// The plugin looks every 10 ms, so a change happened, on average, half that before its stamp.
    public static let detectionLag = 0.005

    public init(page: Int, executor: Int, isOn: Bool, cue: Double?, index: Int?, previousIndex: Int?,
                wasOn: Bool, name: String? = nil, deskTime: Double? = nil) {
        self.deskTime = deskTime
        self.page = page
        self.executor = executor
        self.isOn = isOn
        self.cue = cue
        self.index = index
        self.previousIndex = previousIndex
        self.wasOn = wasOn
        self.name = name
    }

    public static func from(_ m: OSCMessage) -> DeskSequenceEvent? {
        guard m.vividCommand == "seq", m.arguments.count >= 6 else { return nil }
        let a = m.arguments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard let ref = DeskGo.executorRef(a[0]), let page = ref.page else { return nil }
        func on(_ s: String) -> Bool { ["on", "1", "true"].contains(s.lowercased()) }
        func index(_ s: String) -> Int? { Int(s).flatMap { $0 >= 0 ? $0 : nil } }
        let name = a.count > 6 ? a[6] : ""
        let stamp = a.count > 7 ? Double(a[7]).flatMap { $0 >= 0 ? $0 : nil } : nil
        return DeskSequenceEvent(page: page, executor: ref.executor, isOn: on(a[1]),
                                 cue: Double(a[2].replacingOccurrences(of: ",", with: ".")),
                                 index: index(a[3]), previousIndex: index(a[4]), wasOn: on(a[5]),
                                 name: name.isEmpty || name == "-" ? nil : name, deskTime: stamp)
    }

    /// What to record, so playing it back puts the sequence where the desk put it: the next cue
    /// is Go+, the one before is Go-, back to the first is Top, back on where it was is On, off
    /// is Off, and anything else is a Goto to that cue.
    public var action: LaneAction {
        guard isOn else { return .off }
        if !wasOn {
            if let i = index, i == previousIndex { return .on }
            return cue == nil ? .on : .gotoCue
        }
        if let i = index, let p = previousIndex {
            if i == p + 1 { return .goPlus }
            if i == p - 1 { return .goMinus }
            if i == 0 && p > 0 { return .top }
        }
        return cue == nil ? .goPlus : .gotoCue
    }

    /// The trigger's name: the cue's name, or "Cue 5", or "Off".
    public var label: String {
        if !isOn { return "Off" }
        if let name, !name.isEmpty { return name }
        return cue.map { "Cue \(TriggerLane.cueText($0))" } ?? action.label
    }
}

extension DeskRecorder {
    /// The lane a sequence change lands on: the one for exactly that page and executor.
    public static func lane(for event: DeskSequenceEvent, in lanes: [TriggerLane]) -> TriggerLane? {
        lanes.first { $0.page == event.page && $0.executor == event.executor }
    }
}

/// A sequence's name from the desk (the Vivid Labels plugin): `/vivid/label "3.201" "Verse wash"`.
public struct DeskLabel: Equatable, Sendable {
    public var page: Int
    public var executor: Int
    public var name: String

    public init(page: Int, executor: Int, name: String) {
        self.page = page
        self.executor = executor
        self.name = name
    }

    public static func from(_ m: OSCMessage) -> DeskLabel? {
        guard m.vividCommand == "label", m.arguments.count >= 2,
              let ref = DeskGo.executorRef(m.arguments[0].text), let page = ref.page else { return nil }
        let name = m.arguments.dropFirst().map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return DeskLabel(page: page, executor: ref.executor, name: name)
    }

    /// Names every lane that fires this executor, in every song. Returns how many lanes got a new
    /// name and in how many songs.
    @discardableResult
    public func apply(to songs: inout [Song]) -> (lanes: Int, songs: Int) {
        var lanes = 0, touched = 0
        for s in songs.indices {
            guard var list = songs[s].triggerLanes else { continue }
            var changed = false
            for l in list.indices where list[l].page == page && list[l].executor == executor && list[l].name != name {
                list[l].name = name
                lanes += 1
                changed = true
            }
            if changed {
                songs[s].triggerLanes = list
                touched += 1
            }
        }
        return (lanes, touched)
    }
}

/// Puts the desk's own timestamps on this Mac's clock, so a hit records where it happened, not
/// when it got here: the network, the desk's command queue and a busy screen all add delay, and
/// a burst of hits gets spread out. The fastest message in the last little while shows the true
/// offset between the two clocks (the others were held up somewhere); it's kept fresh so the two
/// clocks slowly drifting apart doesn't matter.
public struct DeskClock: Sendable {
    /// How far back the fastest message is looked for.
    public var window: Double = 20
    private var samples: [(at: Double, offset: Double)] = []
    private var wholeSeconds = 0
    private var fractional = false

    public init() {}

    /// This Mac's time (the arrival clock) for something the desk stamped `deskTime`, given it
    /// arrived at `arrival`. Without a usable stamp: the arrival time.
    public mutating func time(desk deskTime: Double?, arrivedAt arrival: Double) -> Double {
        guard let deskTime else { return arrival }
        // A desk clock in whole seconds is no use for timing: fall back to arrival.
        if deskTime == deskTime.rounded(.down) { wholeSeconds += 1 } else { fractional = true }
        if !fractional && wholeSeconds >= 3 { return arrival }
        let offset = arrival - deskTime
        // The plugin restarted or the desk's clock jumped: start again.
        if let best = samples.map(\.offset).min(), abs(offset - best) > 5 { samples.removeAll() }
        samples.append((arrival, offset))
        samples.removeAll { $0.at < arrival - window }
        let best = samples.map(\.offset).min() ?? offset
        return min(arrival, deskTime + best)
    }
}

/// What Vivid itself just fired on the desk, so the desk moving because of it isn't recorded as
/// a press. Times are this Mac's clock (seconds).
public struct DeskEcho: Sendable {
    /// How long after Vivid fires an executor its sequence moving is taken as the echo.
    public var window: Double = 0.75
    private var fired: [String: Double] = [:]

    public init() {}

    public mutating func fired(page: Int, executor: Int, at time: Double) {
        fired["\(page).\(executor)"] = time
        if fired.count > 512 { fired = fired.filter { $0.value > time - 10 } }
    }

    /// The desk moving this executor at `time` is Vivid's own trigger coming back.
    public func isEcho(page: Int, executor: Int, at time: Double) -> Bool {
        guard let t = fired["\(page).\(executor)"] else { return false }
        return time >= t - 0.05 && time <= t + window
    }
}
