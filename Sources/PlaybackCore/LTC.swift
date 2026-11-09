import Foundation

/// One decoded LTC frame and where it sits in the audio.
public struct LTCFrame: Equatable, Sendable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var dropFrame: Bool
    public var userBits: UInt32
    /// Sample where the frame's first bit starts.
    public var startSample: Int
    public var endSample: Int

    public func timecode(rate: FrameRate) -> Timecode? {
        Timecode(hours: hours, minutes: minutes, seconds: seconds, frames: frames, rate: rate)
    }
}

/// SMPTE linear timecode: 80 bits per frame, biphase-mark coded, ending in the sync word.
public enum LTC {
    /// Bits 64...79.
    static let syncWord: [Bool] = [false, false, true, true, true, true, true, true, true, true, true, true, true, true, false, true]

    // MARK: Encoding

    public static func bits(for tc: Timecode, userBits: UInt32 = 0) -> [Bool] {
        var b = [Bool](repeating: false, count: 80)
        func put(_ value: Int, at start: Int, count: Int) {
            for i in 0..<count { b[start + i] = (value >> i) & 1 == 1 }
        }
        let c = tc.components
        put(c.frames % 10, at: 0, count: 4)
        put(c.frames / 10, at: 8, count: 2)
        b[10] = tc.rate.isDropFrame
        put(c.seconds % 10, at: 16, count: 4)
        put(c.seconds / 10, at: 24, count: 3)
        put(c.minutes % 10, at: 32, count: 4)
        put(c.minutes / 10, at: 40, count: 3)
        put(c.hours % 10, at: 48, count: 4)
        put(c.hours / 10, at: 56, count: 2)
        for (i, start) in [4, 12, 20, 28, 36, 44, 52, 60].enumerated() {
            put(Int((userBits >> (4 * UInt32(i))) & 0xF), at: start, count: 4)
        }
        for i in 0..<16 { b[64 + i] = syncWord[i] }
        // Polarity correction: an even number of zeros keeps every frame starting on the same edge.
        let parityBit = tc.rate.nominalFPS == 25 ? 59 : 27
        if b.filter({ !$0 }).count % 2 == 1 { b[parityBit] = true }
        return b
    }

    /// Renders `frameCount` frames of LTC starting at `start`, as a square wave at `amplitude`.
    public static func render(start: Timecode, frameCount: Int, sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
        let samplesPerBit = sampleRate / (start.rate.framesPerSecond * 80)
        let total = Int((Double(frameCount * 80) * samplesPerBit).rounded())
        var out = [Float](repeating: 0, count: total)
        var level: Float = -amplitude
        var bitIndex = 0
        for f in 0..<frameCount {
            let frameBits = bits(for: start.adding(frames: f))
            for bit in frameBits {
                let s0 = Int((Double(bitIndex) * samplesPerBit).rounded())
                let mid = Int(((Double(bitIndex) + 0.5) * samplesPerBit).rounded())
                let s1 = min(total, Int((Double(bitIndex + 1) * samplesPerBit).rounded()))
                level = -level
                if s0 < mid { for i in s0..<min(mid, total) { out[i] = level } }
                if bit { level = -level }
                if mid < s1 { for i in mid..<s1 { out[i] = level } }
                bitIndex += 1
            }
        }
        return out
    }

    // MARK: Decoding

    /// Decodes every LTC frame in `samples`. Copes with either polarity, any level above the
    /// noise floor, DC offset, and rates from 23.976 to 30 fps.
    public static func decode(_ samples: [Float], sampleRate: Double) -> [LTCFrame] {
        guard samples.count > 100 else { return [] }
        // Level and DC offset from the signal itself.
        var mean: Double = 0
        for s in samples { mean += Double(s) }
        mean /= Double(samples.count)
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s - Float(mean))) }
        guard peak > 0.003 else { return [] }
        let threshold = peak * 0.2
        let dc = Float(mean)

        // Zero crossings with hysteresis.
        var transitions: [Int] = []
        transitions.reserveCapacity(samples.count / 8)
        var high = samples[0] - dc > 0
        // A file that starts (or ends) mid-signal starts (or ends) on an edge we can't see.
        if abs(samples[0] - dc) > threshold { transitions.append(0) }
        for (i, raw) in samples.enumerated() {
            let s = raw - dc
            if high && s < -threshold { high = false; transitions.append(i) }
            else if !high && s > threshold { high = true; transitions.append(i) }
        }
        if abs(samples[samples.count - 1] - dc) > threshold { transitions.append(samples.count) }
        guard transitions.count > 160 else { return [] }

        // Bit period: LTC at 23.976–30 fps is 1,920–2,400 bits a second.
        let minPeriod = sampleRate / (30.5 * 80)
        let maxPeriod = sampleRate / (23.5 * 80)
        var intervals: [Double] = []
        intervals.reserveCapacity(transitions.count)
        for i in 1..<transitions.count { intervals.append(Double(transitions[i] - transitions[i - 1])) }
        let longs = intervals.filter { $0 >= minPeriod * 0.8 && $0 <= maxPeriod * 1.2 }.sorted()
        guard !longs.isEmpty else { return [] }
        var period = longs[longs.count / 2]

        var bits: [Bool] = []
        var bitStarts: [Int] = []
        bits.reserveCapacity(intervals.count)
        bitStarts.reserveCapacity(intervals.count)
        var frames: [LTCFrame] = []
        var pendingShort: (start: Int, length: Double)?

        func push(_ bit: Bool, start: Int, end: Int) {
            bits.append(bit)
            bitStarts.append(start)
            let n = bits.count
            guard n >= 80 else { return }
            for i in 0..<16 where bits[n - 16 + i] != syncWord[i] { return }
            let f = n - 80
            func value(_ start: Int, _ count: Int) -> Int {
                var v = 0
                for i in 0..<count where bits[f + start + i] { v |= 1 << i }
                return v
            }
            let fu = value(0, 4), ft = value(8, 2), su = value(16, 4), st = value(24, 3)
            let mu = value(32, 4), mt = value(40, 3), hu = value(48, 4), ht = value(56, 2)
            guard fu < 10, su < 10, mu < 10, hu < 10 else { return }
            let frame = LTCFrame(hours: ht * 10 + hu, minutes: mt * 10 + mu, seconds: st * 10 + su, frames: ft * 10 + fu,
                                 dropFrame: bits[f + 10],
                                 userBits: [4, 12, 20, 28, 36, 44, 52, 60].enumerated().reduce(UInt32(0)) { acc, e in
                                     acc | UInt32(value(e.element, 4)) << (4 * UInt32(e.offset))
                                 },
                                 startSample: bitStarts[f], endSample: end)
            guard frame.hours < 24, frame.minutes < 60, frame.seconds < 60, frame.frames < 30 else { return }
            frames.append(frame)
        }

        for (k, interval) in intervals.enumerated() {
            let start = transitions[k]
            let end = transitions[k + 1]
            if interval > period * 0.75 {
                if interval > period * 1.6 {
                    // Silence or a dropout: start over.
                    pendingShort = nil
                    bits.removeAll(keepingCapacity: true)
                    bitStarts.removeAll(keepingCapacity: true)
                    continue
                }
                // A pending half-bit before a zero means we were out of step; the sync word re-aligns us.
                pendingShort = nil
                push(false, start: start, end: end)
                period = period * 0.97 + interval * 0.03
            } else if interval > period * 0.25 {
                if let p = pendingShort {
                    push(true, start: p.start, end: end)
                    period = period * 0.97 + (p.length + interval) * 0.03
                    pendingShort = nil
                } else {
                    pendingShort = (start, interval)
                }
            } else {
                pendingShort = nil  // a glitch
            }
            if bits.count > 4096 {
                // Keep memory flat on long files; only the last 80 bits matter.
                bits.removeFirst(bits.count - 80)
                bitStarts.removeFirst(bitStarts.count - 80)
            }
        }
        return frames
    }
}

/// What a timecode file holds: where the timecode starts, at what rate, and whether it's clean.
public struct LTCAnalysis: Equatable, Sendable {
    public struct Jump: Equatable, Sendable {
        public var sample: Int
        public var expected: Timecode
        public var found: Timecode
    }

    public var sampleRate: Double
    public var decodedFrames: Int
    public var rate: FrameRate?
    public var first: Timecode?
    public var last: Timecode?
    public var firstSample: Int
    public var lastSample: Int
    /// Places where the timecode doesn't count up by one frame.
    public var jumps: [Jump]
    /// Gaps with no readable timecode, as sample ranges.
    public var dropouts: [Range<Int>]

    public var hasTimecode: Bool { first != nil }

    public var samplesPerFrame: Double {
        guard let r = rate else { return 0 }
        return sampleRate / r.framesPerSecond
    }

    /// The timecode the file would read at `sample`, counted on from the first frame.
    public func timecode(atSample sample: Int) -> Timecode? {
        guard let first, samplesPerFrame > 0 else { return nil }
        // Edges are found a sample or two after they happen; allow 2% of a frame for that.
        let frames = Int((Double(sample - firstSample) / samplesPerFrame + 0.02).rounded(.down))
        return first.adding(frames: frames)
    }

    /// The timecode at the very start of the file (before any leading silence, counted back).
    public var atFileStart: Timecode? { timecode(atSample: 0) }
}

public enum LTCAnalyzer {
    /// Reads the timecode in one channel. `expectedRate` breaks a tie only where the signal can't
    /// (for example a short file that never shows its highest frame number).
    public static func analyze(_ samples: [Float], sampleRate: Double, expectedRate: FrameRate? = nil) -> LTCAnalysis {
        analyze(frames: LTC.decode(samples, sampleRate: sampleRate), sampleRate: sampleRate, expectedRate: expectedRate)
    }

    static func analyze(frames: [LTCFrame], sampleRate: Double, expectedRate: FrameRate?) -> LTCAnalysis {
        var result = LTCAnalysis(sampleRate: sampleRate, decodedFrames: frames.count, rate: nil, first: nil, last: nil,
                                 firstSample: 0, lastSample: 0, jumps: [], dropouts: [])
        guard frames.count >= 2 else { return result }

        // Real speed from the spacing of frames that follow one another.
        var deltas: [Double] = []
        for i in 1..<frames.count { deltas.append(Double(frames[i].startSample - frames[i - 1].startSample)) }
        let median = deltas.sorted()[deltas.count / 2]
        let steady = deltas.filter { abs($0 - median) < median * 0.1 }
        let spf = steady.reduce(0, +) / Double(max(1, steady.count))
        let measuredFPS = sampleRate / spf

        // 24, 25 and 30 are 4% or more apart, so speed alone tells them apart. Within a family,
        // pull-down (23.976, 29.97) is 0.1% slow, which the average spacing also shows.
        let highest = frames.map(\.frames).max() ?? 0
        let drop = frames.filter(\.dropFrame).count * 2 > frames.count
        var nominal = [24, 25, 30].min(by: { abs(Double($0) - measuredFPS) < abs(Double($1) - measuredFPS) })!
        if highest >= nominal { nominal = highest >= 25 ? 30 : 25 }  // labels can't lie about the ceiling
        var rate = FrameRate.closest(toMeasured: measuredFPS, nominal: nominal, dropFrame: drop)
        // Too short to measure the 0.1% reliably: trust the sheet if it's in the same family.
        if steady.count < 30, let e = expectedRate, e.nominalFPS == nominal, e.isDropFrame == drop { rate = e }
        result.rate = rate

        let codes = frames.map { $0.timecode(rate: rate) }
        guard let firstIndex = codes.firstIndex(where: { $0 != nil }) else { return result }
        result.first = codes[firstIndex]
        result.firstSample = frames[firstIndex].startSample
        if let lastIndex = codes.lastIndex(where: { $0 != nil }) {
            result.last = codes[lastIndex]
            result.lastSample = frames[lastIndex].startSample
        }
        var previous: (tc: Timecode, frame: LTCFrame)?
        for (frame, code) in zip(frames, codes) {
            guard let tc = code else { continue }
            if let p = previous {
                let gap = Double(frame.startSample - p.frame.startSample)
                if gap > spf * 1.5 {
                    result.dropouts.append(p.frame.endSample..<frame.startSample)
                    let expected = p.tc.adding(frames: Int((gap / spf).rounded()))
                    if expected != tc { result.jumps.append(.init(sample: frame.startSample, expected: expected, found: tc)) }
                } else if tc != p.tc.adding(frames: 1) {
                    result.jumps.append(.init(sample: frame.startSample, expected: p.tc.adding(frames: 1), found: tc))
                }
            }
            previous = (tc, frame)
        }
        return result
    }

    /// Reads every channel and keeps the one with the most timecode in it.
    public static func analyze(channels: [[Float]], sampleRate: Double, expectedRate: FrameRate? = nil) -> (channel: Int, analysis: LTCAnalysis)? {
        var best: (Int, LTCAnalysis)?
        for (i, ch) in channels.prefix(8).enumerated() {
            let a = analyze(ch, sampleRate: sampleRate, expectedRate: expectedRate)
            if a.decodedFrames > (best?.1.decodedFrames ?? 0) { best = (i, a) }
        }
        return best
    }
}


/// The timecode actually recorded on a track, frame by frame, so the clock shows exactly what
/// is going out (not what the sheet says should be there).
public struct LTCTrack: Sendable {
    public let rate: FrameRate
    public let analysis: LTCAnalysis
    let starts: [Int]
    let codes: [Timecode]
    let samplesPerFrame: Double

    /// Nil when the track has no readable timecode.
    public init?(samples: [Float], sampleRate: Double, expectedRate: FrameRate? = nil) {
        let frames = LTC.decode(samples, sampleRate: sampleRate)
        let analysis = LTCAnalyzer.analyze(frames: frames, sampleRate: sampleRate, expectedRate: expectedRate)
        guard let rate = analysis.rate else { return nil }
        var starts: [Int] = []
        var codes: [Timecode] = []
        for f in frames {
            guard let tc = f.timecode(rate: rate) else { continue }
            starts.append(f.startSample)
            codes.append(tc)
        }
        guard !codes.isEmpty else { return nil }
        self.rate = rate
        self.analysis = analysis
        self.starts = starts
        self.codes = codes
        self.samplesPerFrame = sampleRate / rate.framesPerSecond
    }

    public var first: Timecode? { codes.first }

    /// The frame playing at `sample`, or nil where the track carries no timecode (silence before
    /// it starts, a dropout, or after it ends).
    public func timecode(atSample sample: Int) -> Timecode? {
        // The last frame that starts at or before `sample` (allowing for edge detection lag).
        let target = sample + Int(samplesPerFrame * 0.02)
        var lo = 0, hi = starts.count - 1
        guard hi >= 0, target >= starts[0] else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        let into = Double(target - starts[lo])
        if into < samplesPerFrame * 1.5 { return codes[lo] }
        // The last frame of the file decodes one frame late at most; past that it's silence.
        return nil
    }
}
