import SwiftUI
import AVFoundation
import QuartzCore
import PlaybackCore

/// Settings for this Mac (not the show): devices and networks differ from rig to rig.
struct ControlSettings: Codable, Equatable {
    var mtcOut = false
    var mtcDestination: Int32?
    var artNetOut = false
    var artNetTarget = "2.255.255.255"
    var oscIn = false
    var oscPort: UInt16 = 8000
    var midiRemote = true
    var mmc = true
    var midiMap: [String: MIDITrigger] = [:]
    var follow: FollowSource = .off
    var ltcInputUID: String?
    var ltcInputChannel = 1
    var consoles: [ConsoleTarget] = []
    var fireEarlyMs: Double = 0
    /// A lane's key also fires its executor on the console as it records the trigger.
    var keysFire = true
    /// The command that names an executor's sequence, for Import Labels to Console.
    var labelTemplate = ExecutorLabel.defaultTemplate
    /// The UDP port MIDI Show Control arrives on from the network (Record from the desk).
    var mscPort: UInt16 = 6004
    /// Which network port (its system name, "en7") each protocol uses; nil lets macOS choose.
    /// Consoles carry their own.
    var artNetOutPort: String?
    var oscInPort: String?
    var artNetInPort: String?
    var mscInPort: String?
    /// Record desk also starts the Vivid Recorder plugin on the consoles, and stopping stops it,
    /// so it never runs when nobody's recording.
    var deskPluginFollows = true

    init() {}

    /// Settings saved by an older version load with defaults for anything new.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControlSettings()
        mtcOut = try c.decodeIfPresent(Bool.self, forKey: .mtcOut) ?? d.mtcOut
        mtcDestination = try c.decodeIfPresent(Int32.self, forKey: .mtcDestination)
        artNetOut = try c.decodeIfPresent(Bool.self, forKey: .artNetOut) ?? d.artNetOut
        artNetTarget = try c.decodeIfPresent(String.self, forKey: .artNetTarget) ?? d.artNetTarget
        oscIn = try c.decodeIfPresent(Bool.self, forKey: .oscIn) ?? d.oscIn
        oscPort = try c.decodeIfPresent(UInt16.self, forKey: .oscPort) ?? d.oscPort
        midiRemote = try c.decodeIfPresent(Bool.self, forKey: .midiRemote) ?? d.midiRemote
        mmc = try c.decodeIfPresent(Bool.self, forKey: .mmc) ?? d.mmc
        midiMap = try c.decodeIfPresent([String: MIDITrigger].self, forKey: .midiMap) ?? d.midiMap
        follow = try c.decodeIfPresent(FollowSource.self, forKey: .follow) ?? d.follow
        ltcInputUID = try c.decodeIfPresent(String.self, forKey: .ltcInputUID)
        ltcInputChannel = try c.decodeIfPresent(Int.self, forKey: .ltcInputChannel) ?? d.ltcInputChannel
        consoles = try c.decodeIfPresent([ConsoleTarget].self, forKey: .consoles) ?? d.consoles
        fireEarlyMs = try c.decodeIfPresent(Double.self, forKey: .fireEarlyMs) ?? d.fireEarlyMs
        keysFire = try c.decodeIfPresent(Bool.self, forKey: .keysFire) ?? d.keysFire
        labelTemplate = try c.decodeIfPresent(String.self, forKey: .labelTemplate) ?? d.labelTemplate
        // The old built-in default addressed executors the wrong way; a template Caiden wrote stays.
        if labelTemplate == ExecutorLabel.oldDefaultTemplate { labelTemplate = ExecutorLabel.defaultTemplate }
        mscPort = try c.decodeIfPresent(UInt16.self, forKey: .mscPort) ?? d.mscPort
        artNetOutPort = try c.decodeIfPresent(String.self, forKey: .artNetOutPort)
        oscInPort = try c.decodeIfPresent(String.self, forKey: .oscInPort)
        artNetInPort = try c.decodeIfPresent(String.self, forKey: .artNetInPort)
        mscInPort = try c.decodeIfPresent(String.self, forKey: .mscInPort)
        deskPluginFollows = try c.decodeIfPresent(Bool.self, forKey: .deskPluginFollows) ?? d.deskPluginFollows
    }

    static func load() -> ControlSettings {
        guard let data = UserDefaults.standard.data(forKey: "controlSettings"),
              let s = try? JSONDecoder().decode(ControlSettings.self, from: data) else { return ControlSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "controlSettings") }
    }
}

enum FollowSource: String, Codable, CaseIterable, Identifiable {
    case off, ltc, mtc, artNet
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .ltc: return "LTC in"
        case .mtc: return "MTC"
        case .artNet: return "Art-Net"
        }
    }
}

/// Buttons a MIDI controller can be taught.
enum RemoteAction: String, CaseIterable, Identifiable {
    case play, stop, toggle, next, previous, top, marker
    var id: String { rawValue }
    var label: String {
        switch self {
        case .play: return "Go"
        case .stop: return "Stop"
        case .toggle: return "Go / Stop"
        case .next: return "Next song"
        case .previous: return "Previous song"
        case .top: return "Top of song"
        case .marker: return "Add marker"
        }
    }
    var symbol: String {
        switch self {
        case .play: return "play.fill"
        case .stop: return "stop.fill"
        case .toggle: return "playpause.fill"
        case .next: return "forward.end.fill"
        case .previous: return "backward.end.fill"
        case .top: return "arrow.uturn.backward"
        case .marker: return "flag.fill"
        }
    }
    var command: RemoteCommand {
        switch self {
        case .play: return .play
        case .stop: return .stop
        case .toggle: return .toggle
        case .next: return .next
        case .previous: return .previous
        case .top: return .top
        case .marker: return .marker
        }
    }
}

/// Timecode out (MTC, Art-Net), remote control (OSC, MIDI) and following incoming timecode.
@MainActor
final class ControlCenter: ObservableObject {
    @Published var settings = ControlSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            apply(old: oldValue)
        }
    }
    @Published private(set) var midiDestinations: [MIDIEndpoint] = []
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var oscStatus = ""
    /// The last OSC messages that arrived. Its own object, so a busy desk only redraws the list
    /// on the Connections page, never the timeline.
    let oscMonitor = OSCMonitor()
    private func heard(_ text: String, from: String, meaning: String?) {
        oscMonitor.add(OSCMonitor.Heard(text: text, from: from, meaning: meaning, at: Date()))
    }
    @Published private(set) var lastRemote: (text: String, at: Date)?
    @Published var learning: RemoteAction?
    /// Incoming timecode while following, and when it last arrived.
    // Not published: these change every frame while following, and publishing them redrew every
    // view that watches the control centre. The Connections page reads them on its own timer.
    private(set) var incoming: Timecode?
    private(set) var incomingAt: Double = 0
    @Published private(set) var followStatus = "Off"
    @Published private(set) var followProblem: String?
    /// This Mac's network ports with an address, looked at again every few seconds.
    @Published private(set) var networkPorts: [NetworkPort] = UDPSocket.networkPorts()
    private var portTicks = 0

    let midi = MIDIService()
    let sender: TimecodeSender
    let triggers: TriggerService
    /// When each trigger last fired (for the gold flash in the timeline).
    @Published private(set) var firedAt: [UUID: Date] = [:]
    /// When each lane last fired a trigger (the lane's pulse).
    @Published private(set) var laneFiredAt: [UUID: Date] = [:]
    /// The last trigger sent, for the Consoles section.
    private(set) var lastTrigger: (text: String, ok: Bool, at: Date)?
    /// Lights a trigger in the timeline as if it had just fired.
    func flash(_ id: UUID?, lane: UUID?) {
        let now = Date()
        if let id { firedAt[id] = now }
        if let lane { laneFiredAt[lane] = now }
    }
    /// Set by the app model: re-arm triggers when consoles or timing change.
    var onTriggerSettingsChange: (() -> Void)?
    private let netQueue = DispatchQueue(label: "vivid.network.in", qos: .userInteractive)
    private var osc: UDPSocket?
    private var artNetIn: UDPSocket?
    private let ltcInput = LTCInput()
    private var mtcReader = MTCReader()
    private var chase = ChaseEngine()
    private var tickTimer: Timer?

    /// Set by the app model.
    var onCommand: ((RemoteCommand) -> Void)?
    /// A GO from the desk (OSC /vivid/exec or MIDI Show Control), for Record from the desk.
    /// With the moment it arrived (CACurrentMediaTime), taken on the network thread, so how busy
    /// the screen is doesn't move it.
    var onDeskGo: ((DeskGo, Double) -> Void)?
    /// A sequence on the desk changed cue, from the Vivid Recorder plugin, and when it arrived.
    var onDeskSequence: ((DeskSequenceEvent, Double) -> Void)?
    /// A sequence's name from the desk, from the Vivid Labels plugin.
    var onDeskLabel: ((DeskLabel) -> Void)?
    private var mscIn: UDPSocket?
    @Published private(set) var deskStatus = ""
    var onFollow: (([ChaseEngine.Action]) -> Void)?
    var followContext: (() -> (songs: [Song], current: UUID?, playhead: Double, playing: Bool))?
    var followRate: () -> FrameRate = { .fps30 }

    init(clock: OutputClock) {
        sender = TimecodeSender(clock: clock, midi: midi)
        triggers = TriggerService(clock: clock)
        // Triggers fired by playback pulse straight from the playhead (on the clock you hear);
        // only manual fires (Fire Now, lane keys) go through `flash`.
        triggers.onFire = nil
        triggers.onSend = { [weak self] text, ok in
            Task { @MainActor in self?.lastTrigger = (text, ok, Date()) }
        }
        refreshDevices()
        midi.onSetupChange = { [weak self] in self?.refreshDevices() }
        midi.setReceiver { [weak self] message in
            Task { @MainActor in self?.midiMessage(message) }
        }
        apply(old: nil)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followTick() }
        }
    }

    func refreshDevices() {
        midiDestinations = MIDIService.destinations()
        inputDevices = AudioDevices.inputs()
    }

    var addresses: [String] { UDPSocket.localAddresses().map(\.address) }

    /// A console that's this Mac (onPC) on the same port OSC in listens on: what Vivid sends it
    /// can land back in Vivid instead. Nil when there's no clash.
    var portClash: ConsoleTarget? {
        guard settings.oscIn else { return nil }
        let mine = Set(addresses + ["127.0.0.1", "localhost"])
        return settings.consoles.first { $0.enabled && $0.port == settings.oscPort && (mine.contains($0.host) || $0.host.hasPrefix("127.")) }
    }

    // MARK: Applying settings

    private func apply(old: ControlSettings?) {
        if old?.consoles != settings.consoles || old?.fireEarlyMs != settings.fireEarlyMs { onTriggerSettingsChange?() }
        sender.configure(.init(mtc: settings.mtcOut, mtcDestination: settings.mtcDestination,
                               artNet: settings.artNetOut, artNetTarget: settings.artNetTarget,
                               artNetPort: settings.artNetOutPort))
        if old?.oscIn != settings.oscIn || old?.oscPort != settings.oscPort || old?.oscInPort != settings.oscInPort { startOSC() }
        if old?.follow != settings.follow || old?.ltcInputUID != settings.ltcInputUID || old?.ltcInputChannel != settings.ltcInputChannel
            || old?.artNetInPort != settings.artNetInPort {
            startFollow()
        }
        if old?.mscInPort != settings.mscInPort || old?.mscPort != settings.mscPort, mscIn != nil || !deskStatus.isEmpty {
            listenForDesk(true)
        }
    }

    // MARK: Network ports

    /// "USB LAN" for a port's system name, "Automatic" for none.
    func portLabel(_ name: String?) -> String {
        guard let name else { return "Automatic" }
        return networkPorts.first { $0.name == name }?.label ?? name
    }

    /// The port with this system name, if it's up.
    func port(_ name: String?) -> NetworkPort? {
        guard let name else { return nil }
        return networkPorts.first { $0.name == name }
    }

    /// Looks at the network ports again. When a chosen port comes or goes, whatever listens on
    /// it starts again, so a replugged adapter is picked back up without touching anything.
    func refreshNetworkPorts() {
        let now = UDPSocket.networkPorts()
        guard now != networkPorts else { return }
        let before = Set(networkPorts.map(\.name)), after = Set(now.map(\.name))
        networkPorts = now
        let changed = before.symmetricDifference(after)
        if let p = settings.oscInPort, changed.contains(p) { startOSC() }
        if let p = settings.artNetInPort, changed.contains(p), settings.follow == .artNet { startFollow() }
        if let p = settings.mscInPort, changed.contains(p), mscIn != nil || !deskStatus.isEmpty { listenForDesk(true) }
    }

    /// Why a listener tied to `port` can't start, in plain words.
    private func unavailable(_ port: String?) -> String? {
        guard let port, if_nametoindex(port) == 0 || self.port(port) == nil else { return nil }
        return "\(portLabel(port)) isn't connected. Nothing is heard until it's back."
    }

    private func startOSC() {
        osc = nil
        guard settings.oscIn else { oscStatus = "Off"; return }
        if let why = unavailable(settings.oscInPort) { oscStatus = why; return }
        guard let socket = UDPSocket(listenOn: settings.oscPort, networkPort: settings.oscInPort, shared: false) else {
            oscStatus = "Port \(settings.oscPort) is in use by another app (grandMA3 onPC on this Mac listens on 8000). Choose another port, like 8001."
            return
        }
        socket.listen(on: netQueue) { [weak self] data, from in
            let arrived = CACurrentMediaTime()
            let messages = OSCMessage.parse(data)
            Task { @MainActor in
                guard let self else { return }
                if messages.isEmpty { self.heard("\(data.count) bytes that aren't OSC", from: from, meaning: nil) }
                for m in messages {
                    let text = ([m.address] + m.arguments.map(\.text)).joined(separator: " ")
                    if let label = DeskLabel.from(m) {
                        self.heard(text, from: from, meaning: "desk name \(label.page).\(label.executor)")
                        self.onDeskLabel?(label)
                        continue
                    }
                    if let event = DeskSequenceEvent.from(m) {
                        self.heard(text, from: from, meaning: "desk: \(event.page).\(event.executor) \(event.action.label)")
                        self.onDeskSequence?(event, arrived)
                        continue
                    }
                    if let go = DeskGo.from(m) {
                        self.heard(text, from: from, meaning: "desk GO \(go.label)")
                        self.onDeskGo?(go, arrived)
                        continue
                    }
                    guard let cmd = RemoteCommand.from(m) else {
                        self.heard(text, from: from, meaning: nil)
                        continue
                    }
                    self.heard(text, from: from, meaning: "\(cmd)")
                    self.run(cmd, from: "OSC \(m.address) from \(from)")
                }
            }
        }
        osc = socket
        oscStatus = "Listening on port \(settings.oscPort)" + (settings.oscInPort == nil ? "" : " · \(portLabel(settings.oscInPort))")
    }

    private func run(_ cmd: RemoteCommand, from source: String) {
        lastRemote = (source, Date())
        onCommand?(cmd)
    }

    // MARK: MIDI in

    /// Listens for MIDI Show Control over the network while recording from the desk (MIDI
    /// itself is always heard). Only while armed, so nothing listens when it isn't wanted.
    func listenForDesk(_ on: Bool) {
        mscIn = nil
        guard on else { deskStatus = ""; return }
        if let why = unavailable(settings.mscInPort) {
            deskStatus = "MIDI Show Control over the network: " + why
            return
        }
        guard let socket = UDPSocket(listenOn: settings.mscPort, networkPort: settings.mscInPort, shared: false) else {
            deskStatus = "Port \(settings.mscPort) is in use: MIDI Show Control over the network can't be heard. OSC and MIDI still work."
            return
        }
        socket.listen(on: netQueue) { [weak self] data, _ in
            let arrived = CACurrentMediaTime()
            guard let go = DeskGo.from(msc: data) else { return }
            Task { @MainActor in self?.onDeskGo?(go, arrived) }
        }
        mscIn = socket
        deskStatus = "Listening on port \(settings.mscPort)" + (settings.mscInPort == nil ? "" : " · \(portLabel(settings.mscInPort))")
    }

    private func midiMessage(_ m: [UInt8]) {
        // A GO in MIDI Show Control (Record from the desk).
        if m.first == 0xF0, let go = DeskGo.from(msc: m) {
            onDeskGo?(go, CACurrentMediaTime())
            return
        }
        // MIDI timecode (for following).
        if settings.follow == .mtc, m.first == 0xF1 || (m.count >= 10 && m[0] == 0xF0 && m[3] == 0x01) {
            if let tc = mtcReader.receive(m) { received(tc, at: CACurrentMediaTime()) }
            return
        }
        // Learning a button.
        if let action = learning, let trigger = MIDITrigger(message: m) {
            var map = settings.midiMap
            map = map.filter { $0.value != trigger }
            map[action.rawValue] = trigger
            settings.midiMap = map
            learning = nil
            return
        }
        guard settings.midiRemote else { return }
        if settings.mmc, let mmc = MMCCommand.parse(m) {
            switch mmc {
            case .play: run(.play, from: "MIDI Machine Control: play")
            case .stop: run(.stop, from: "MIDI Machine Control: stop")
            case .fastForward: run(.next, from: "MIDI Machine Control: fast forward")
            case .rewind: run(.previous, from: "MIDI Machine Control: rewind")
            case let .locate(h, mi, s, f):
                run(.locate(String(format: "%02d:%02d:%02d:%02d", h, mi, s, f)), from: "MIDI Machine Control: locate")
            }
            return
        }
        if let trigger = MIDITrigger(message: m),
           let action = settings.midiMap.first(where: { $0.value == trigger }).flatMap({ RemoteAction(rawValue: $0.key) }) {
            run(action.command, from: "MIDI \(trigger.displayName)")
        }
    }

    // MARK: Following incoming timecode

    private func startFollow() {
        ltcInput.stop()
        artNetIn = nil
        mtcReader = MTCReader()
        chase = ChaseEngine()
        incoming = nil
        followProblem = nil
        switch settings.follow {
        case .off:
            followStatus = "Off"
        case .mtc:
            followStatus = "Waiting for MIDI timecode"
        case .artNet:
            if let why = unavailable(settings.artNetInPort) {
                followProblem = why
                followStatus = "Can't listen"
                return
            }
            guard let socket = UDPSocket(listenOn: ArtNetTimecode.port, networkPort: settings.artNetInPort) else {
                followProblem = "Art-Net port 6454 is in use by another app on this Mac."
                followStatus = "Can't listen"
                return
            }
            socket.listen(on: netQueue) { [weak self] data, _ in
                guard let tc = ArtNetTimecode.parse(data) else { return }
                let at = CACurrentMediaTime()
                Task { @MainActor in self?.received(tc, at: at) }
            }
            artNetIn = socket
            followStatus = "Waiting for Art-Net timecode"
        case .ltc:
            followStatus = "Waiting for LTC"
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard granted else {
                        self.followProblem = "Vivid Playback isn't allowed to use audio inputs. Allow it in System Settings › Privacy & Security › Microphone."
                        self.followStatus = "No access to inputs"
                        return
                    }
                    do {
                        try self.ltcInput.start(deviceUID: self.settings.ltcInputUID, channel: self.settings.ltcInputChannel) { [weak self] frame, at in
                            Task { @MainActor in
                                guard let self else { return }
                                let rate: FrameRate = frame.dropFrame ? .fps29_97DF : self.followRate()
                                if let tc = frame.timecode(rate: rate) { self.received(tc, at: at) }
                            }
                        }
                    } catch {
                        self.followProblem = "Couldn't open that input: \(error.localizedDescription)"
                        self.followStatus = "Can't listen"
                    }
                }
            }
        }
    }

    private func received(_ tc: Timecode, at time: Double) {
        incoming = tc
        incomingAt = time
        guard settings.follow != .off, let ctx = followContext?() else { return }
        let actions = chase.receive(tc, at: time, songs: ctx.songs, currentSongID: ctx.current, playhead: ctx.playhead, playing: ctx.playing)
        if let found = ChaseEngine.locate(tc, in: ctx.songs) {
            followStatus = chase.isRunning ? "Following · \(found.song.title)" : "Parked · \(found.song.title)"
        } else {
            followStatus = "No song at \(tc)"
        }
        if !actions.isEmpty { onFollow?(actions) }
    }

    private func followTick() {
        portTicks += 1
        if portTicks % 60 == 0 { refreshNetworkPorts() }   // every 3 seconds
        guard settings.follow != .off, let ctx = followContext?() else { return }
        let actions = chase.tick(at: CACurrentMediaTime(), playing: ctx.playing)
        // Only when it changes: setting a published value redraws everything watching it.
        if CACurrentMediaTime() - incomingAt > 0.5, incoming != nil, followStatus != "Timecode stopped" {
            followStatus = "Timecode stopped"
        }
        if !actions.isEmpty { onFollow?(actions) }
    }

    var isFollowing: Bool { settings.follow != .off }
}

/// The last OSC messages that arrived, newest first, and what became of them.
@MainActor
final class OSCMonitor: ObservableObject {
    struct Heard: Identifiable {
        let id = UUID()
        let text: String
        let from: String
        let meaning: String?
        let at: Date
    }
    @Published private(set) var items: [Heard] = []

    func add(_ h: Heard) {
        items.insert(h, at: 0)
        if items.count > 8 { items.removeLast(items.count - 8) }
    }
}
