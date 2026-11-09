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
    @Published private(set) var lastRemote: (text: String, at: Date)?
    @Published var learning: RemoteAction?
    /// Incoming timecode while following, and when it last arrived.
    @Published private(set) var incoming: Timecode?
    @Published private(set) var incomingAt: Double = 0
    @Published private(set) var followStatus = "Off"
    @Published private(set) var followProblem: String?

    let midi = MIDIService()
    let sender: TimecodeSender
    let triggers: TriggerService
    /// When each trigger last fired (for the gold flash in the timeline).
    @Published private(set) var firedAt: [UUID: Date] = [:]
    /// The last trigger sent, for the Consoles section.
    @Published private(set) var lastTrigger: (text: String, ok: Bool, at: Date)?
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
    var onFollow: (([ChaseEngine.Action]) -> Void)?
    var followContext: (() -> (songs: [Song], current: UUID?, playhead: Double, playing: Bool))?
    var followRate: () -> FrameRate = { .fps30 }

    init(clock: OutputClock) {
        sender = TimecodeSender(clock: clock, midi: midi)
        triggers = TriggerService(clock: clock)
        triggers.onFire = { [weak self] id in
            Task { @MainActor in self?.firedAt[id] = Date() }
        }
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

    // MARK: Applying settings

    private func apply(old: ControlSettings?) {
        if old?.consoles != settings.consoles || old?.fireEarlyMs != settings.fireEarlyMs { onTriggerSettingsChange?() }
        sender.configure(.init(mtc: settings.mtcOut, mtcDestination: settings.mtcDestination,
                               artNet: settings.artNetOut, artNetTarget: settings.artNetTarget))
        if old?.oscIn != settings.oscIn || old?.oscPort != settings.oscPort { startOSC() }
        if old?.follow != settings.follow || old?.ltcInputUID != settings.ltcInputUID || old?.ltcInputChannel != settings.ltcInputChannel {
            startFollow()
        }
    }

    private func startOSC() {
        osc = nil
        guard settings.oscIn else { oscStatus = "Off"; return }
        guard let socket = UDPSocket(listenOn: settings.oscPort) else {
            oscStatus = "Port \(settings.oscPort) is in use by another app. Choose another port."
            return
        }
        socket.listen(on: netQueue) { [weak self] data, from in
            let messages = OSCMessage.parse(data)
            Task { @MainActor in
                for m in messages {
                    guard let cmd = RemoteCommand.from(m) else { continue }
                    self?.run(cmd, from: "OSC \(m.address) from \(from)")
                }
            }
        }
        osc = socket
        oscStatus = "Listening on port \(settings.oscPort)"
    }

    private func run(_ cmd: RemoteCommand, from source: String) {
        lastRemote = (source, Date())
        onCommand?(cmd)
    }

    // MARK: MIDI in

    private func midiMessage(_ m: [UInt8]) {
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
            guard let socket = UDPSocket(listenOn: ArtNetTimecode.port) else {
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
        guard settings.follow != .off, let ctx = followContext?() else { return }
        let actions = chase.tick(at: CACurrentMediaTime(), playing: ctx.playing)
        if CACurrentMediaTime() - incomingAt > 0.5, incoming != nil {
            followStatus = "Timecode stopped"
        }
        if !actions.isEmpty { onFollow?(actions) }
    }

    var isFollowing: Bool { settings.follow != .off }
}
