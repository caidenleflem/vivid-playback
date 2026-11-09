import Foundation

/// Reads LTC as it arrives, block by block (an audio input), keeping its place between blocks.
public final class LTCStreamDecoder: @unchecked Sendable {
    public let sampleRate: Double
    private var sampleIndex = 0
    private var high = false
    private var peak: Float = 0
    private var lastTransition = -1
    private var period: Double
    private var pendingShort: (start: Int, length: Double)?
    private var bits: [Bool] = []
    private var bitStarts: [Int] = []

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // Midway between 24 and 30 fps; it adapts within a few bits.
        period = sampleRate / (27 * 80)
    }

    /// Decodes a block; returns the frames that completed in it (startSample counts from the
    /// first sample ever fed).
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [LTCFrame] {
        var frames: [LTCFrame] = []
        for s in samples {
            let a = abs(s)
            peak = max(a, peak * 0.99995)
            let threshold = max(0.003, peak * 0.2)
            var crossed = false
            if high && s < -threshold { high = false; crossed = true } else if !high && s > threshold { high = true; crossed = true }
            if crossed {
                if lastTransition >= 0 { interval(from: lastTransition, to: sampleIndex, into: &frames) }
                lastTransition = sampleIndex
            }
            sampleIndex += 1
        }
        return frames
    }

    public func process(_ samples: [Float]) -> [LTCFrame] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    private func interval(from start: Int, to end: Int, into frames: inout [LTCFrame]) {
        let length = Double(end - start)
        let minPeriod = sampleRate / (30.5 * 80), maxPeriod = sampleRate / (23.5 * 80)
        if length > period * 1.6 || length > maxPeriod * 2 {
            pendingShort = nil
            bits.removeAll(keepingCapacity: true)
            bitStarts.removeAll(keepingCapacity: true)
            return
        }
        if length > period * 0.75 {
            pendingShort = nil
            push(false, start: start, end: end, into: &frames)
            period = min(maxPeriod, max(minPeriod, period * 0.9 + length * 0.1))
        } else if length > period * 0.25 {
            if let p = pendingShort {
                push(true, start: p.start, end: end, into: &frames)
                period = min(maxPeriod, max(minPeriod, period * 0.9 + (p.length + length) * 0.1))
                pendingShort = nil
            } else {
                pendingShort = (start, length)
            }
        } else {
            pendingShort = nil
        }
    }

    private func push(_ bit: Bool, start: Int, end: Int, into frames: inout [LTCFrame]) {
        bits.append(bit)
        bitStarts.append(start)
        if bits.count > 160 {
            bits.removeFirst(bits.count - 80)
            bitStarts.removeFirst(bitStarts.count - 80)
        }
        let n = bits.count
        guard n >= 80 else { return }
        for i in 0..<16 where bits[n - 16 + i] != LTC.syncWord[i] { return }
        let f = n - 80
        func value(_ s: Int, _ c: Int) -> Int { (0..<c).reduce(0) { $0 | (bits[f + s + $1] ? 1 << $1 : 0) } }
        let fu = value(0, 4), su = value(16, 4), mu = value(32, 4), hu = value(48, 4)
        guard fu < 10, su < 10, mu < 10, hu < 10 else { return }
        let frame = LTCFrame(hours: value(56, 2) * 10 + hu, minutes: value(40, 3) * 10 + mu, seconds: value(24, 3) * 10 + su,
                             frames: value(8, 2) * 10 + fu, dropFrame: bits[f + 10], userBits: 0,
                             startSample: bitStarts[f], endSample: end)
        guard frame.hours < 24, frame.minutes < 60, frame.seconds < 60, frame.frames < 30 else { return }
        frames.append(frame)
        bits.removeAll(keepingCapacity: true)
        bitStarts.removeAll(keepingCapacity: true)
    }
}

/// Follows incoming timecode (LTC, MTC or Art-Net): finds the song it belongs to, cues and plays
/// it in step, corrects drift, and stops when the timecode stops. Pure logic; the app carries
/// out the actions.
public struct ChaseEngine: Sendable {
    public enum Action: Equatable, Sendable {
        case cue(UUID, at: Double)
        case play
        case stop
        case locate(Double)
    }

    /// Seconds without timecode before playback stops.
    public var dropoutSeconds: Double = 0.4
    /// Frames of drift tolerated before relocating.
    public var driftFrames: Int = 2

    public private(set) var lastTimecode: Timecode?
    private var lastReceived: Double = -1
    private var runningCount = 0
    public private(set) var isRunning = false

    public init() {}

    /// The song (from `songs`, in order) whose timecode range holds `tc`, and the position in it.
    public static func locate(_ tc: Timecode, in songs: [Song]) -> (song: Song, seconds: Double)? {
        for song in songs where song.hasTimecode {
            let t = Timecode(tc.description, rate: song.rate) ?? Timecode(seconds: tc.seconds, rate: song.rate)
            let seconds = Double(t.frames(since: song.start)) / song.rate.framesPerSecond
            if seconds >= -song.fileOffset && seconds < (song.length ?? .infinity) { return (song, seconds) }
        }
        return nil
    }

    /// Feed one incoming timecode. `playhead` is the transport's position in the current song.
    public mutating func receive(_ tc: Timecode, at time: Double, songs: [Song], currentSongID: UUID?,
                                 playhead: Double, playing: Bool) -> [Action] {
        defer { lastTimecode = tc; lastReceived = time }
        // Running means the timecode is counting up, frame by frame.
        if let last = lastTimecode, time - lastReceived < 0.25 {
            let step = tc.frames(since: Timecode(last.description, rate: tc.rate) ?? last)
            runningCount = (1...3).contains(step) ? runningCount + 1 : 0
        } else {
            runningCount = 0
        }
        isRunning = runningCount >= 2

        guard let target = Self.locate(tc, in: songs) else {
            return playing && isRunning ? [.stop] : []
        }
        // A frame takes 1/fps to arrive: it describes the moment it started.
        let seconds = target.seconds
        if target.song.id != currentSongID {
            return isRunning ? [.cue(target.song.id, at: seconds), .play] : [.cue(target.song.id, at: seconds)]
        }
        guard isRunning else { return playing ? [] : [.locate(seconds)] }
        if !playing { return [.locate(seconds), .play] }
        let drift = abs(playhead - seconds) * target.song.rate.framesPerSecond
        return drift > Double(driftFrames) ? [.locate(seconds)] : []
    }

    /// Call regularly: stops playback when timecode stops arriving.
    public mutating func tick(at time: Double, playing: Bool) -> [Action] {
        guard lastReceived >= 0, time - lastReceived > dropoutSeconds else { return [] }
        let wasRunning = isRunning
        isRunning = false
        runningCount = 0
        return playing && wasRunning ? [.stop] : []
    }

    public var lastReceivedAt: Double { lastReceived }
}

extension Mixer {
    /// Peak level of each output channel over a block (for meters).
    public static func peaks(_ outputs: UnsafeBufferPointer<UnsafeMutablePointer<Float>?>, frames: Int,
                             into peaks: UnsafeMutablePointer<Float>, count: Int) {
        for c in 0..<min(count, outputs.count) {
            guard let p = outputs[c] else { peaks[c] = 0; continue }
            var m: Float = 0
            for i in 0..<frames { m = max(m, abs(p[i])) }
            peaks[c] = max(peaks[c], m)
        }
    }
}
