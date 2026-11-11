import Foundation

/// A song's bars and beats: a steady tempo and where a bar starts. Times are seconds from the
/// song's start (its start timecode), like the playhead. Drawn in the song timeline; markers
/// only move onto it when Caiden asks (snap while dragging, or Tighten to the beat).
public struct BeatGrid: Codable, Hashable, Sendable {
    public var bpm: Double
    /// Seconds from the song's start where a bar begins (beat 1). Any bar will do.
    public var downbeat: Double
    public var beatsPerBar: Int
    /// How much of the song the grid lines up with, 0…1, when it was found from the master.
    /// Nil when it was typed in.
    public var fit: Double?
    /// Where the music stops following the grid (a tempo change, a live section), if it does.
    public var driftsAt: Double?

    public init(bpm: Double, downbeat: Double = 0, beatsPerBar: Int = 4, fit: Double? = nil, driftsAt: Double? = nil) {
        self.bpm = bpm
        self.downbeat = downbeat
        self.beatsPerBar = beatsPerBar
        self.fit = fit
        self.driftsAt = driftsAt
    }

    public static let tempoRange: ClosedRange<Double> = 40...300

    public var beatLength: Double { 60 / max(1, bpm) }
    public var barLength: Double { beatLength * Double(max(1, beatsPerBar)) }

    /// The beat at `seconds`, counting from the downbeat (0 is that bar's beat 1). Fractional.
    public func beat(at seconds: Double) -> Double { (seconds - downbeat) / beatLength }

    public func time(ofBeat beat: Double) -> Double { downbeat + beat * beatLength }

    /// Bar and beat at a time, both counted from 1, with bar 1 the first bar that starts at or
    /// after the song's start (bars before it count 0, -1…).
    public func barBeat(at seconds: Double) -> (bar: Int, beat: Int) {
        let n = max(1, beatsPerBar)
        let b = Int((beat(at: seconds) + 1e-6).rounded(.down)) - firstBarBeat
        let bar = Int((Double(b) / Double(n)).rounded(.down))
        let inBar = b - bar * n
        return (bar + 1, inBar + 1)
    }

    /// The beat index (from the downbeat) of the first bar at or after the song's start (a bar
    /// a hair before the start, within 60 ms, is bar 1).
    private var firstBarBeat: Int {
        let n = Double(max(1, beatsPerBar))
        let slack = 0.06 / beatLength
        return Int(((beat(at: 0) - slack) / n).rounded(.up) * n)
    }

    /// Every beat between two times, with whether it starts a bar, and the bar's number.
    public func beats(from a: Double, to b: Double) -> [(time: Double, isBar: Bool, bar: Int)] {
        guard b > a, bpm > 0 else { return [] }
        let first = Int(beat(at: a).rounded(.up)), last = Int(beat(at: b).rounded(.down))
        guard last >= first, last - first < 100_000 else { return [] }
        let n = max(1, beatsPerBar)
        return (first...last).map { i in
            let t = time(ofBeat: Double(i))
            let isBar = ((i % n) + n) % n == 0
            return (t, isBar, barBeat(at: t).bar)
        }
    }

    /// How finely markers snap.
    public enum Division: String, Codable, CaseIterable, Sendable, Identifiable {
        case bar, beat, half, quarter
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .bar: return "Bar"
            case .beat: return "Beat"
            case .half: return "½ beat"
            case .quarter: return "¼ beat"
            }
        }
        func step(beatsPerBar: Int) -> Double {
            switch self {
            case .bar: return Double(max(1, beatsPerBar))
            case .beat: return 1
            case .half: return 0.5
            case .quarter: return 0.25
            }
        }
    }

    /// The nearest grid point to `seconds`.
    public func snap(_ seconds: Double, to division: Division) -> Double {
        let step = division.step(beatsPerBar: beatsPerBar)
        return time(ofBeat: (beat(at: seconds) / step).rounded() * step)
    }

    /// Snaps a frame count (from the song's start) to the grid, landing on a whole frame.
    public func snapFrame(_ frame: Int, fps: Double, to division: Division) -> Int {
        Int((snap(Double(frame) / fps, to: division) * fps).rounded())
    }

    /// Moves the bar line by whole beats (when detection put bar 1 on the wrong beat).
    public mutating func shiftBar(beats: Int) { downbeat += Double(beats) * beatLength }

    /// A bar starts here; the tempo stays.
    public mutating func barStarts(at seconds: Double) { downbeat = seconds }

    /// Moves the whole grid a little (seconds), to line it up by ear.
    public mutating func nudge(by seconds: Double) { downbeat += seconds }

    /// Keeps the grid where it is under `anchor` while the tempo changes.
    public mutating func setTempo(_ newBPM: Double, keeping anchor: Double) {
        let b = beat(at: anchor)
        bpm = min(Self.tempoRange.upperBound, max(Self.tempoRange.lowerBound, newBPM))
        downbeat = anchor - b * beatLength
        fit = nil
        driftsAt = nil
    }

    /// Twice as fast or half as fast, keeping bar 1 where it is (when detection counted the
    /// hi-hats, or every other beat).
    public mutating func double() { setTempo(bpm * 2, keeping: downbeat) }
    public mutating func halve() { setTempo(bpm / 2, keeping: downbeat) }

    /// "128 BPM" or "127.98 BPM".
    public var tempoText: String {
        let r = (bpm * 100).rounded() / 100
        return r == r.rounded() ? "\(Int(r)) BPM" : String(format: "%.2f BPM", r)
    }
}

/// Finds the tempo and the beat in a master. Built for click-tracked songs (a steady tempo):
/// where the music stops following one tempo, it says where instead of bending the grid.
public enum BeatDetector {
    /// The onset envelope's rate: 100 values a second.
    static let envelopeRate = 100.0

    /// `samples` is the master in mono at `sampleRate`; `fileOffset` is where the song starts in
    /// the file (seconds). Nil when there's no steady beat to find (silence, a pad, speech).
    public static func detect(_ samples: [Float], sampleRate: Double, fileOffset: Double = 0,
                              beatsPerBar: Int = 4) -> BeatGrid? {
        guard sampleRate > 0, samples.count > Int(sampleRate * 4) else { return nil }
        let (onset, low) = envelopes(samples, sampleRate: sampleRate)
        // Real hits only: a steady pad's level ripples a little, and that isn't a beat.
        let strongest = onset.sorted(by: >)
        guard onset.count > 300, strongest[strongest.count / 100] > 0.1 else { return nil }
        guard let coarse = coarseTempo(onset) else { return nil }
        // The repeat that's strongest can be a beat and a half, or two: try the tempos it's
        // related to and keep the one whose hits line up best (leaning to pop's usual range).
        var best: (bpm: Double, phase: Double, score: Double, weighted: Double)?
        for ratio in [1.0, 2.0, 0.5, 1.5, 2.0 / 3.0] {
            let c = coarse * ratio
            guard (55...220).contains(c), let r = refine(onset, around: c) else { continue }
            let weighted = r.score * lean(r.bpm)
            if best == nil || weighted > best!.weighted { best = (r.bpm, r.phase, r.score, weighted) }
        }
        guard let (bpm, phase, score, _) = best, score > 1.25 else { return nil }
        let period = envelopeRate * 60 / bpm
        // Envelope frame t covers the hop starting at t: a hit lands, on average, half a hop in.
        let lag = -0.5 / envelopeRate
        let firstBeatFile = phase / envelopeRate - lag
        let beat = 60 / bpm
        // Beats in song time.
        var anchor = firstBeatFile - fileOffset
        // The song's start is very often bar 1: a beat right on it takes the bar.
        let nearest = (anchor / beat).rounded()
        let onStart = abs(anchor - nearest * beat) < 0.06
        if onStart {
            anchor -= nearest * beat
        } else {
            anchor = strongestBar(low: low, phase: phase, period: period, beatsPerBar: beatsPerBar) / envelopeRate - lag - fileOffset
        }
        let (fit, drifts) = fitAlong(onset, phase: phase, period: period)
        return BeatGrid(bpm: bpm, downbeat: anchor, beatsPerBar: beatsPerBar, fit: fit,
                        driftsAt: drifts.map { $0 / envelopeRate - fileOffset })
    }

    // MARK: Envelopes

    /// Spectral-ish flux at 100 Hz from three bands (lows for the kick, the top for hats and
    /// snares, and everything), half-wave rectified with the local average taken off. Also the
    /// lows' own flux, for finding bar 1.
    static func envelopes(_ x: [Float], sampleRate: Double) -> (onset: [Double], low: [Double]) {
        let hop = max(1, Int((sampleRate / envelopeRate).rounded()))
        let frames = x.count / hop
        let a = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        var lp: Float = 0, prev: Float = 0
        var eLow = [Double](repeating: 0, count: frames)
        var eHigh = eLow, eAll = eLow
        x.withUnsafeBufferPointer { p in
            for f in 0..<frames {
                var l: Float = 0, h: Float = 0, all: Float = 0
                let base = f * hop
                for i in base..<(base + hop) {
                    let s = p[i]
                    lp += a * (s - lp)
                    let d = s - prev
                    prev = s
                    l += lp * lp
                    h += d * d
                    all += s * s
                }
                eLow[f] = Double(l); eHigh[f] = Double(h); eAll[f] = Double(all)
            }
        }
        func flux(_ e: [Double]) -> [Double] {
            let peak = max(e.max() ?? 0, 1e-12)
            var out = [Double](repeating: 0, count: e.count)
            var last = log10((e.first ?? 0) / peak + 1e-6)
            for i in 0..<e.count {
                let v = log10(e[i] / peak + 1e-6)
                out[i] = max(0, v - last)
                last = v
            }
            return out
        }
        let fl = flux(eLow), fh = flux(eHigh), fa = flux(eAll)
        var onset = [Double](repeating: 0, count: frames)
        for i in 0..<frames { onset[i] = fl[i] + fh[i] + 0.5 * fa[i] }
        return (detrend(onset), detrend(fl))
    }

    /// Takes off a half-second running mean and keeps what's above it.
    static func detrend(_ x: [Double]) -> [Double] {
        let w = 25
        guard x.count > 2 * w else { return x }
        var sum = 0.0
        var out = [Double](repeating: 0, count: x.count)
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { sum += x[i]; prefix[i + 1] = sum }
        for i in 0..<x.count {
            let lo = max(0, i - w), hi = min(x.count, i + w + 1)
            let mean = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            out[i] = max(0, x[i] - mean)
        }
        return out
    }

    // MARK: Tempo

    /// The tempo the onsets repeat at most strongly, leaning towards the 80–160 BPM a pop song
    /// usually counts in, so a busy hi-hat doesn't double it.
    static func coarseTempo(_ raw: [Double]) -> Double? {
        let minLag = Int(envelopeRate * 60 / 200), maxLag = Int(envelopeRate * 60 / 60)
        guard raw.count > maxLag * 4 else { return nil }
        // Blurred a couple of frames, so a beat that doesn't fall on a whole frame (126.4 BPM is
        // 47.47 frames) still lines up with itself; otherwise its double length wins.
        var o = raw
        for i in 2..<(raw.count - 2) {
            o[i] = (raw[i - 2] + 2 * raw[i - 1] + 3 * raw[i] + 2 * raw[i + 1] + raw[i + 2]) / 9
        }
        var ac = [Double](repeating: 0, count: maxLag * 4 + 1)
        let n = o.count
        o.withUnsafeBufferPointer { p in
            for lag in minLag...(maxLag * 4) where lag < n {
                var s = 0.0
                for t in 0..<(n - lag) { s += p[t] * p[t + lag] }
                ac[lag] = s / Double(n - lag)
            }
        }
        var best: (lag: Int, score: Double)?
        for lag in minLag...maxLag {
            // A beat repeats at its lag and its multiples.
            var s = 0.0
            for k in 1...4 where lag * k < ac.count { s += ac[lag * k] / Double(k) }
            let score = s * lean(envelopeRate * 60 / Double(lag))
            if best == nil || score > best!.score { best = (lag, score) }
        }
        guard let b = best, b.score > 0 else { return nil }
        return envelopeRate * 60 / Double(b.lag)
    }

    /// How likely a tempo is for a song: most count between 80 and 160.
    static func lean(_ bpm: Double) -> Double { exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)) }

    /// Folds the envelope at each candidate tempo and keeps the one whose beats line up best,
    /// to a hundredth of a BPM (a tenth off drifts almost half a beat over four minutes).
    /// Returns the tempo, where the beat falls (an envelope frame) and how clearly it stands out.
    static func refine(_ o: [Double], around coarse: Double) -> (bpm: Double, phase: Double, score: Double)? {
        func fold(_ bpm: Double) -> (phase: Double, score: Double) {
            let period = envelopeRate * 60 / bpm
            let bins = max(8, Int(period * 4))
            var hist = [Double](repeating: 0, count: bins)
            for t in 0..<o.count where o[t] > 0 {
                let r = Double(t).truncatingRemainder(dividingBy: period)
                hist[min(bins - 1, Int(r / period * Double(bins)))] += o[t]
            }
            // Smooth a little (a few milliseconds either way), around the circle.
            var smooth = hist
            for i in 0..<bins {
                var s = 0.0
                for d in -3...3 { s += hist[(i + d + bins) % bins] * (1 - Double(abs(d)) / 4) }
                smooth[i] = s
            }
            let mean = smooth.reduce(0, +) / Double(bins)
            guard let (i, peak) = smooth.enumerated().max(by: { $0.element < $1.element }).map({ ($0.offset, $0.element) }),
                  mean > 0 else { return (0, 0) }
            return ((Double(i) + 0.5) / Double(bins) * period, peak / mean)
        }
        var best: (bpm: Double, phase: Double, score: Double)?
        func consider(_ bpm: Double) {
            let (phase, score) = fold(bpm)
            if best == nil || score > best!.score { best = (bpm, phase, score) }
        }
        var bpm = coarse * 0.97
        while bpm <= coarse * 1.03 { consider(bpm); bpm += 0.05 }
        guard let rough = best else { return nil }
        bpm = rough.bpm - 0.06
        while bpm <= rough.bpm + 0.06 { consider(bpm); bpm += 0.005 }
        return best
    }

    /// Bar 1 by the lows: of the beats in a bar, the one the kick hits hardest.
    static func strongestBar(low: [Double], phase: Double, period: Double, beatsPerBar: Int) -> Double {
        let n = max(1, beatsPerBar)
        var sums = [Double](repeating: 0, count: n)
        var k = 0
        var t = phase
        while t < Double(low.count) {
            let i = Int(t.rounded())
            var peak = 0.0
            for j in max(0, i - 3)...min(low.count - 1, i + 3) { peak = max(peak, low[j]) }
            sums[k % n] += peak
            k += 1
            t += period
        }
        let first = sums.enumerated().max { $0.element < $1.element }?.offset ?? 0
        return phase + Double(first) * period
    }

    /// How much of the song the grid holds for, in 8-beat stretches, and the first stretch
    /// where the music has moved off it (two in a row more than 35 ms out).
    static func fitAlong(_ o: [Double], phase: Double, period: Double) -> (fit: Double, driftsAt: Double?) {
        let window = 8
        let tolerance = 0.035 * envelopeRate
        var held = 0, judged = 0, outRun = 0
        var drifts: Double?
        var beat = 0
        while true {
            let start = phase + Double(beat) * period
            guard start + Double(window) * period < Double(o.count) else { break }
            // Where this stretch's onsets sit relative to the grid: the offset that gathers most.
            var bestOffset = 0.0, bestSum = 0.0, total = 0.0
            for off in stride(from: -period * 0.3, through: period * 0.3, by: 0.5) {
                var s = 0.0
                for b in 0..<window {
                    let t = start + Double(b) * period + off
                    let i = Int(t.rounded())
                    if i >= 0 && i < o.count { s += o[i] + 0.5 * (i > 0 ? o[i - 1] : 0) + 0.5 * (i + 1 < o.count ? o[i + 1] : 0) }
                }
                total += s
                if s > bestSum { bestSum = s; bestOffset = off }
            }
            if bestSum > 0 && total > 0 {
                judged += 1
                if abs(bestOffset) <= tolerance {
                    held += 1
                    outRun = 0
                } else {
                    outRun += 1
                    if outRun == 2 && drifts == nil { drifts = start - Double(window) * period }
                }
            }
            beat += window
        }
        return (judged == 0 ? 0 : Double(held) / Double(judged), drifts)
    }
}
