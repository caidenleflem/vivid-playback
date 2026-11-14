import Foundation
import QuartzCore
import PlaybackCore

/// Fires executor triggers over OSC as the playhead passes them. Runs on its own high-priority
/// queue against the position you hear, so a busy screen can't make a cue late.
final class TriggerService: @unchecked Sendable {
    private struct Armed {
        var songID: UUID
        var triggers: [TriggerScheduler.Trigger]
        var payload: [UUID: (lane: TriggerLane, marker: Marker)]
        var fps: Double
    }

    private let clock: OutputClock
    private let queue = DispatchQueue(label: "vivid.triggers", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var armed: Armed?
    private var consoles: [ConsoleTarget] = []
    private var earlySeconds: Double = 0
    private var scheduler = TriggerScheduler()
    private var lastSong: UUID?
    /// One socket per network port, made as needed (queue only). Key "" is macOS's choice.
    private var sockets: [String: UDPSocket] = [:]

    /// The socket for a console's network port (queue only). Nil if that port isn't there.
    private func socket(for console: ConsoleTarget) -> UDPSocket? {
        let key = console.networkPort ?? ""
        if let s = sockets[key] { return s }
        let s = UDPSocket(networkPort: console.networkPort)
        sockets[key] = s
        return s
    }

    /// Sends one message to a console; drops a port's socket that failed so the next send makes
    /// a fresh one (an adapter unplugged and plugged back in).
    private func send(_ bytes: [UInt8], to console: ConsoleTarget) -> Bool {
        guard let s = socket(for: console) else {
            lastError = "The network port picked for \(console.name) (\(console.networkPort ?? "?")) isn't connected."
            return false
        }
        let ok = s.send(bytes, to: console.host, port: console.port)
        if !ok {
            lastError = s.lastError
            sockets[console.networkPort ?? ""] = nil
        }
        return ok
    }

    /// Why the last send failed (queue only).
    private var lastError: String?

    /// What was fired on the desk, so the desk moving because of it isn't recorded as a press.
    private var echo = DeskEcho()
    private let echoLock = NSLock()

    /// The desk moving this executor at `time` (CACurrentMediaTime) is Vivid's own trigger coming back.
    func isEcho(page: Int, executor: Int, at time: Double) -> Bool {
        echoLock.lock(); defer { echoLock.unlock() }
        return echo.isEcho(page: page, executor: executor, at: time)
    }
    /// Called on the main queue with each fired trigger and its lane.
    var onFire: ((UUID, UUID) -> Void)?
    /// Called on the main queue after each send: what went where, and whether it left this Mac.
    var onSend: ((String, Bool) -> Void)?

    init(clock: OutputClock) {
        self.clock = clock
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// The current song's triggers, the lanes they belong to, and the consoles.
    func update(song: Song?, lanes: [TriggerLane], consoles: [ConsoleTarget], fireEarlyMs: Double) {
        var next: Armed?
        if let song {
            let byID = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
            var triggers: [TriggerScheduler.Trigger] = []
            var payload: [UUID: (TriggerLane, Marker)] = [:]
            for m in song.markers {
                guard let laneID = m.laneID, let lane = byID[laneID], !lane.muted else { continue }
                triggers.append(.init(frame: m.time.frames(since: song.start), id: m.id))
                payload[m.id] = (lane, m)
            }
            next = Armed(songID: song.id, triggers: triggers, payload: payload, fps: song.rate.framesPerSecond)
        }
        lock.lock()
        armed = next
        self.consoles = consoles
        earlySeconds = max(0, fireEarlyMs) / 1000
        lock.unlock()
    }

    /// Sends one trigger now (Fire now, and testing a lane).
    func fire(lane: TriggerLane, marker: Marker?) {
        lock.lock(); let consoles = self.consoles; lock.unlock()
        queue.async { self.send(lane: lane, marker: marker, consoles: consoles) }
    }

    private func tick() {
        lock.lock(); let armed = self.armed; let consoles = self.consoles; let early = earlySeconds; lock.unlock()
        let now = clock.position(at: CACurrentMediaTime() + early)
        guard let armed, let song = now.song, song.id == armed.songID else {
            scheduler.reset()
            return
        }
        if lastSong != song.id { scheduler.reset(); lastSong = song.id }
        let frame = Int((now.seconds * armed.fps + 1e-6).rounded(.down))
        let fired = scheduler.advance(to: frame, running: now.running, triggers: armed.triggers)
        for id in fired {
            guard let p = armed.payload[id] else { continue }
            send(lane: p.lane, marker: p.marker, consoles: consoles)
            let cb = onFire, laneID = p.lane.id
            DispatchQueue.main.async { cb?(id, laneID) }
        }
    }

    /// Sends one command line to the consoles at once and waits until it's gone (for quitting).
    func sendNow(_ command: String, consoles: [ConsoleTarget]) {
        queue.sync {
            for console in consoles { _ = self.send(console.command(command).encoded(), to: console) }
        }
    }

    /// Sends command lines (one after another, a few milliseconds apart so a console isn't
    /// flooded), then reports how many went out and how many couldn't leave this Mac.
    func sendCommands(_ items: [(command: String, consoles: [ConsoleTarget])], done: @escaping (Int, Int) -> Void) {
        queue.async {
            var sent = 0, failed = 0
            for item in items {
                for console in item.consoles {
                    if self.send(console.command(item.command).encoded(), to: console) {
                        sent += 1
                    } else {
                        failed += 1
                    }
                    usleep(15_000)
                }
            }
            DispatchQueue.main.async { done(sent, failed) }
        }
    }

    private func send(lane: TriggerLane, marker: Marker?, consoles: [ConsoleTarget]) {
        let targets = lane.targets(in: consoles)
        var ok = !targets.isEmpty
        lastError = nil
        if !targets.isEmpty {
            echoLock.lock(); echo.fired(page: lane.page, executor: lane.executor, at: CACurrentMediaTime()); echoLock.unlock()
        }
        for console in targets {
            for message in lane.messages(for: marker, console: console) {
                if !send(message.encoded(), to: console) { ok = false }
            }
        }
        let what = lane.commandLine(for: marker) ?? "Fader \(lane.page).\(lane.executor) at \(Int((marker?.value ?? 100).rounded()))%"
        var text = targets.isEmpty ? "\(what) · no console to send to" : "\(what) → \(targets.map(\.name).joined(separator: ", "))"
        if !ok, let why = lastError { text += " · \(why)" }
        let cb = onSend
        DispatchQueue.main.async { cb?(text, ok) }
    }
}
