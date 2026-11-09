import Foundation
import QuartzCore
import PlaybackCore

/// Sends MIDI timecode and Art-Net timecode, following the output clock (the same timecode as
/// the LTC). Runs on its own high-priority queue so the UI can't make it stutter.
final class TimecodeSender: @unchecked Sendable {
    struct Config: Equatable {
        var mtc = false
        var mtcDestination: Int32?
        var artNet = false
        var artNetTarget = "2.255.255.255"
    }

    private let clock: OutputClock
    private let midi: MIDIService
    private let queue = DispatchQueue(label: "vivid.timecode.out", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var config = Config()
    private var socket = UDPSocket()

    // Sender state (queue only).
    private var piece = 0
    private var latched: Timecode?
    private var nextQuarter: Double = 0
    private var lastSeen: Timecode?
    private var lastRunning = false
    private var lastArtNet: Timecode?
    private var artNetFailed = false

    // For the UI.
    private var _lastSent: Timecode?
    private var _lastSentAt: Double = 0
    private var _artNetError = false

    init(clock: OutputClock, midi: MIDIService) {
        self.clock = clock
        self.midi = midi
    }

    func configure(_ c: Config) {
        lock.lock(); config = c; lock.unlock()
        if c.mtc || c.artNet { start() } else { stop() }
    }

    /// What was last sent and when, and whether Art-Net sends are failing.
    var status: (timecode: Timecode?, at: Double, artNetError: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_lastSent, _lastSentAt, _artNetError)
    }

    private func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        lock.lock(); let c = config; lock.unlock()
        let now = CACurrentMediaTime()
        let (tc, running) = clock.now(at: now)
        guard let tc else {
            lastSeen = nil
            lastRunning = false
            return
        }
        defer {
            lastSeen = tc
            lastRunning = running
        }
        // Stopped, or jumped: a full frame says where we are.
        let jumped = lastSeen.map { !(0...2).contains(tc.frames(since: $0)) } ?? true
        if !running {
            if tc != lastSeen || lastRunning { sendFull(tc, c) }
            return
        }
        if !lastRunning || jumped {
            sendFull(tc, c)
            piece = 0
            nextQuarter = now
        }
        if c.mtc {
            let quarter = 1 / (tc.rate.framesPerSecond * 4)
            if now - nextQuarter > 0.25 { nextQuarter = now }   // after a stall, don't flood
            while now >= nextQuarter {
                if piece == 0 { latched = clock.now(at: nextQuarter).timecode ?? tc }
                if let l = latched { midi.send(MTC.quarterFrame(piece, of: l), to: c.mtcDestination) }
                piece = (piece + 1) & 7
                nextQuarter += quarter
            }
        }
        if c.artNet && tc != lastArtNet {
            sendArtNet(tc, c)
        }
        noteSent(tc, now)
    }

    private func sendFull(_ tc: Timecode, _ c: Config) {
        if c.mtc { midi.send(MTC.fullFrame(tc), to: c.mtcDestination) }
        if c.artNet { sendArtNet(tc, c) }
        noteSent(tc, CACurrentMediaTime())
    }

    private func sendArtNet(_ tc: Timecode, _ c: Config) {
        let ok = socket?.send(ArtNetTimecode.packet(tc), to: c.artNetTarget, port: ArtNetTimecode.port) ?? false
        lastArtNet = tc
        lock.lock(); _artNetError = !ok; lock.unlock()
    }

    private func noteSent(_ tc: Timecode, _ at: Double) {
        lock.lock(); _lastSent = tc; _lastSentAt = at; lock.unlock()
    }
}
