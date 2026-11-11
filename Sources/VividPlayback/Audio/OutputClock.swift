import Foundation
import QuartzCore
import PlaybackCore

/// The timecode going out, readable from any thread (the MTC and Art-Net senders run on their
/// own queue). The transport keeps it current; the audio thread's position is read live.
final class OutputClock: @unchecked Sendable {
    private let lock = NSLock()
    private let state: RenderState
    private var song: Song?
    private var buffers: PlaybackBuffers?
    private var sampleRate: Double = 48_000
    private var latency: Double = 0
    private var usesAudio = false
    private var clockRunning = false
    private var anchorPosition: Double = 0
    private var anchorTime: Double = 0
    private var testStart: Timecode?
    /// Songs armed to follow, by serial, and the advance count the transport has caught up to:
    /// once the audio runs into the next song, the clock follows it at once.
    private var arms: [Int: (song: Song, buffers: PlaybackBuffers)] = [:]
    private var seenAdvances = 0

    init(state: RenderState) { self.state = state }

    func update(song: Song?, buffers: PlaybackBuffers?, sampleRate: Double, latency: Double, usesAudio: Bool,
                clockRunning: Bool, anchorPosition: Double, anchorTime: Double,
                arms: [Int: (song: Song, buffers: PlaybackBuffers)] = [:], seenAdvances: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        self.arms = arms
        self.seenAdvances = seenAdvances
        self.song = song
        self.buffers = buffers
        self.sampleRate = sampleRate
        self.latency = latency
        self.usesAudio = usesAudio
        self.clockRunning = clockRunning
        self.anchorPosition = anchorPosition
        self.anchorTime = anchorTime
    }

    func setTest(_ start: Timecode?) {
        lock.lock(); testStart = start; lock.unlock()
    }

    /// The song being heard: the armed one once the audio has run into it. Call with the lock held.
    private func heard() -> (Song?, PlaybackBuffers?) {
        if usesAudio, state.advances != seenAdvances, let a = arms[state.advancedSerial] { return (a.song, a.buffers) }
        return (song, buffers)
    }

    /// Where the playhead is in the current song (seconds from its start), as heard.
    func position(at time: Double = CACurrentMediaTime()) -> (song: Song?, seconds: Double, running: Bool) {
        lock.lock()
        let (song, buffers) = heard()
        let rate = sampleRate, latency = self.latency
        let usesAudio = self.usesAudio, clockRunning = self.clockRunning, anchor = anchorPosition, anchorTime = self.anchorTime
        lock.unlock()
        guard let song else { return (nil, 0, false) }
        if usesAudio, buffers != nil {
            var frames = Double(state.pendingLocate >= 0 ? state.pendingLocate : state.renderedPosition)
            let running = state.playing
            if running {
                frames += min(0.1, max(0, time - state.renderedAt)) * rate
                frames -= latency * rate
            }
            return (song, frames / rate - song.fileOffset, running)
        }
        return (song, clockRunning ? anchor + (time - anchorTime) : anchor, clockRunning)
    }

    /// The timecode at this moment, and whether it's running. Nil where nothing is sent.
    func now(at time: Double = CACurrentMediaTime()) -> (timecode: Timecode?, running: Bool) {
        lock.lock()
        let (song, buffers) = heard()
        let rate = sampleRate, latency = self.latency
        let usesAudio = self.usesAudio, clockRunning = self.clockRunning, anchor = anchorPosition, anchorTime = self.anchorTime
        let testStart = self.testStart
        lock.unlock()

        if let testStart, !state.playing, state.test != nil {
            let frames = Int(Double(state.testPosition) / rate * testStart.rate.framesPerSecond)
            return (testStart.adding(frames: frames), true)
        }
        guard let song, song.hasTimecode else { return (nil, false) }
        if usesAudio, let buffers {
            var frames = Double(state.pendingLocate >= 0 ? state.pendingLocate : state.renderedPosition)
            let running = state.playing
            if running {
                frames += min(0.1, max(0, time - state.renderedAt)) * rate
                frames -= latency * rate
            }
            switch buffers.source {
            case .file:
                return (buffers.ltc?.timecode(atSample: Int(frames)), running)
            case .unreadable, .none:
                return (nil, false)
            case .generated:
                let position = frames / rate - song.fileOffset
                return (song.start.adding(frames: Int((position * song.rate.framesPerSecond + 1e-6).rounded(.down))), running)
            }
        }
        let position = clockRunning ? anchor + (time - anchorTime) : anchor
        return (song.start.adding(frames: Int((position * song.rate.framesPerSecond + 1e-6).rounded(.down))), clockRunning)
    }
}
