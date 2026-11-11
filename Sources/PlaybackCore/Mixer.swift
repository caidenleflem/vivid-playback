import Foundation

/// Where the master and the timecode go on the interface. Channels are 0-based here;
/// `OutputRouting` (what Caiden picks) is 1-based.
public struct OutputMap: Equatable, Sendable {
    public var channelCount: Int
    public var masterLeft: Int?
    public var masterRight: Int?
    public var timecode: Int?

    public init(channelCount: Int, masterLeft: Int?, masterRight: Int?, timecode: Int?) {
        self.channelCount = channelCount
        self.masterLeft = masterLeft
        self.masterRight = masterRight
        self.timecode = timecode
    }

    /// Maps the show's routing onto an interface with `channelCount` outputs. A channel the
    /// interface doesn't have is left out (never moved somewhere else).
    public init(routing: OutputRouting, channelCount: Int) {
        self.init(routing: routing, slots: [OutputSlot(uid: routing.deviceUID ?? "", outputs: channelCount)])
    }

    /// Maps the show's routing onto one or more interfaces played as one: their outputs follow
    /// each other in order (the first interface's, then the second's). The master is on the first
    /// interface; timecode on the one the routing names. A channel an interface doesn't have,
    /// or timecode on an interface that isn't there, is left out: never moved somewhere else.
    public init(routing: OutputRouting, slots: [OutputSlot]) {
        let total = slots.reduce(0) { $0 + max(0, $1.outputs) }
        func channel(_ c: Int?, in slot: Int?) -> Int? {
            guard let c, let slot, slot < slots.count, c >= 1, c <= slots[slot].outputs else { return nil }
            return slots[..<slot].reduce(0) { $0 + max(0, $1.outputs) } + c - 1
        }
        let timecodeSlot: Int? = routing.splitsInterfaces
            ? slots.indices.dropFirst().first { slots[$0].uid == routing.timecodeDeviceUID }
                ?? (slots.first?.uid == routing.timecodeDeviceUID ? 0 : nil)
            : 0
        channelCount = total
        masterLeft = channel(routing.masterChannels.first, in: 0)
        masterRight = routing.masterChannels.count > 1 ? channel(routing.masterChannels[1], in: 0) : nil
        timecode = channel(routing.timecodeChannel, in: timecodeSlot)
        // Timecode never shares a channel with the master.
        if let t = timecode, t == masterLeft || t == masterRight { timecode = nil }
    }
}

/// One interface in the output, and how many outputs it has.
public struct OutputSlot: Equatable, Sendable {
    public var uid: String
    public var outputs: Int
    public init(uid: String, outputs: Int) {
        self.uid = uid
        self.outputs = outputs
    }
}

/// One song's audio, ready to play: the master (one or two channels) and the timecode track,
/// at the interface's sample rate, sample-aligned (sample n of each belongs together).
/// Allocated once when the song is loaded; the realtime thread only reads it.
/// Where a song's timecode comes from, as shown to the person.
public enum TimecodeSource: Equatable, Sendable {
    /// Played straight from the song's timecode file.
    case file(String)
    /// The song has no timecode file: generated from the sheet's start.
    case generated
    /// The sheet gives the song no timecode: none is sent.
    case none
    /// The song has a timecode file that couldn't be read: none is sent, never a substitute.
    case unreadable(String)
}

public final class PlaybackBuffers: @unchecked Sendable {
    public let sampleRate: Double
    public let frameCount: Int
    public let masterChannels: Int
    let master: UnsafeMutablePointer<Float>   // channel-major: [ch0 frames][ch1 frames]
    let timecode: UnsafeMutablePointer<Float>?
    /// True when the timecode was generated from the sheet rather than read from a file.
    public var timecodeGenerated: Bool { source == .generated }
    public let source: TimecodeSource
    /// The timecode actually on the track (file timecode only), for the clock.
    public let ltc: LTCTrack?

    public convenience init(sampleRate: Double, master: [[Float]], timecode: [Float]?, timecodeGenerated: Bool = false) {
        self.init(sampleRate: sampleRate, master: master, timecode: timecode,
                  source: timecodeGenerated ? .generated : (timecode == nil ? .none : .file("")), ltc: nil)
    }

    public init(sampleRate: Double, master: [[Float]], timecode: [Float]?, source: TimecodeSource, ltc: LTCTrack?) {
        self.sampleRate = sampleRate
        let channels = Array(master.prefix(2))
        let frames = max(channels.map(\.count).max() ?? 0, timecode?.count ?? 0)
        self.frameCount = frames
        self.masterChannels = max(1, channels.count)
        self.source = source
        self.ltc = ltc
        let m = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames * masterChannels))
        m.initialize(repeating: 0, count: max(1, frames * masterChannels))
        for (c, ch) in channels.enumerated() {
            ch.withUnsafeBufferPointer { src in
                (m + c * frames).update(from: src.baseAddress!, count: min(src.count, frames))
            }
        }
        self.master = m
        if let timecode {
            let t = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames))
            t.initialize(repeating: 0, count: max(1, frames))
            timecode.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { t.update(from: base, count: min(src.count, frames)) }
            }
            self.timecode = t
        } else {
            self.timecode = nil
        }
    }

    deinit {
        master.deallocate()
        timecode?.deallocate()
    }

    public var duration: Double { Double(frameCount) / sampleRate }
    /// Memory the song takes while loaded.
    public var byteCount: Int { frameCount * (masterChannels + (timecode == nil ? 0 : 1)) * MemoryLayout<Float>.size }

    public func masterSample(channel: Int, frame: Int) -> Float { master[min(channel, masterChannels - 1) * frameCount + frame] }
    public func timecodeSample(frame: Int) -> Float { timecode?[frame] ?? 0 }
}

/// A stretch of the song to repeat, in frames.
public struct LoopRegion: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public enum Mixer {
    public static func gain(dB: Double) -> Float { Float(pow(10, dB / 20)) }

    /// Fills `frames` frames of every output channel, starting at `position` in the song, and
    /// returns the next position. Master and timecode come from the same frame index, so they
    /// can't drift. Past the end it plays silence (and no timecode). The timecode level is fixed;
    /// `masterGain` never touches it. Allocation-free, for the realtime audio thread.
    @inline(__always)
    public static func render(_ buffers: PlaybackBuffers?, position: Int, frames: Int,
                              into outputs: UnsafeBufferPointer<UnsafeMutablePointer<Float>?>,
                              map: OutputMap, masterGain: Float, timecodeGain: Float,
                              loop: LoopRegion? = nil) -> Int {
        for out in outputs {
            out?.update(repeating: 0, count: frames)
        }
        return add(buffers, position: position, frames: frames, at: 0, into: outputs, map: map,
                   masterGain: masterGain, timecodeGain: timecodeGain, loop: loop)
    }

    /// Renders a block for a playhead: the song, then, the sample it ends, the song armed after
    /// it (no gap, timecode and master together). Just after a cut, the master crossfades from
    /// the song cut away from in a few milliseconds, so it doesn't click. The fade never touches
    /// the timecode output: the new song's timecode starts on the first sample.
    /// Allocation-free, for the realtime audio thread.
    public static func render(_ head: inout Playhead, frames: Int,
                              into outputs: UnsafeBufferPointer<UnsafeMutablePointer<Float>?>,
                              map: OutputMap, masterGain: Float, timecodeGain: Float,
                              loop: LoopRegion? = nil) {
        for out in outputs {
            out?.update(repeating: 0, count: frames)
        }
        var done = 0
        while done < frames {
            var n = frames - done
            if loop == nil, let b = head.buffers, let next = head.next {
                let left = b.frameCount - head.position
                if left <= 0 {
                    head.buffers = next
                    head.position = 0
                    head.next = nil
                    head.advances &+= 1
                    continue
                }
                n = min(n, left)
            }
            head.position = add(head.buffers, position: head.position, frames: n, at: done, into: outputs, map: map,
                                masterGain: masterGain, timecodeGain: timecodeGain, loop: loop)
            done += n
        }
        if head.fadeLeft > 0, let tail = head.tail, head.fadeLength > 0 {
            // A crossfade on the master only: the new song rises as the old one falls, so the two
            // never add up past full level. The timecode output isn't touched.
            let n = min(frames, head.fadeLeft)
            let length = Float(head.fadeLength)
            let into = Float(head.fadeLength - head.fadeLeft)
            let left = map.masterLeft.flatMap { $0 < outputs.count ? outputs[$0] : nil }
            var right = map.masterRight.flatMap { $0 < outputs.count ? outputs[$0] : nil }
            if right == left { right = nil }
            if let left { for i in 0..<n { left[i] *= (into + Float(i)) / length } }
            if let right { for i in 0..<n { right[i] *= (into + Float(i)) / length } }
            let step = masterGain / length
            head.tailPosition = add(tail, position: head.tailPosition, frames: n, at: 0, into: outputs, map: map,
                                    masterGain: Float(head.fadeLeft) * step, timecodeGain: 0, rampStep: step,
                                    includeTimecode: false)
            head.fadeLeft -= n
        }
        if head.fadeLeft <= 0 { head.tail = nil }
        // A master turned up past 0 dB goes through the limiter so it can't clip.
        if masterGain > 1 {
            let left = map.masterLeft.flatMap { $0 < outputs.count ? outputs[$0] : nil }
            var right = map.masterRight.flatMap { $0 < outputs.count ? outputs[$0] : nil }
            if right == left { right = nil }
            if let left { limit(left, frames: frames) }
            if let right { limit(right, frames: frames) }
        }
    }

    /// Adds `frames` frames of `buffers` from `position` into the outputs starting at output frame
    /// `offset`, and returns the next position. With `rampStep`, the master gain falls by that much
    /// each frame (a fade-out).
    @inline(__always)
    static func add(_ buffers: PlaybackBuffers?, position: Int, frames: Int, at offset: Int,
                    into outputs: UnsafeBufferPointer<UnsafeMutablePointer<Float>?>,
                    map: OutputMap, masterGain: Float, timecodeGain: Float, loop: LoopRegion? = nil,
                    rampStep: Float = 0, includeTimecode: Bool = true) -> Int {
        guard let b = buffers else { return position }
        let left = map.masterLeft.flatMap { $0 < outputs.count ? outputs[$0] : nil }
        var right = map.masterRight.flatMap { $0 < outputs.count ? outputs[$0] : nil }
        if right == left { right = nil }   // both sides on one output: summed, never doubled
        let tc = includeTimecode ? map.timecode.flatMap { $0 < outputs.count ? outputs[$0] : nil } : nil
        let rightSource = b.masterChannels > 1 ? b.frameCount : 0
        // The master on a single output (a two-output laptop: music left, timecode right) is
        // summed to mono so nothing is lost.
        let monoSum = right == nil && b.masterChannels > 1
        var gain = masterGain
        var pos = position
        var i = offset
        let end = offset + frames
        while i < end {
            if let loop, loop.end > loop.start, pos >= loop.end { pos = loop.start }
            if pos >= 0 && pos < b.frameCount {
                let l = b.master[pos]
                let r = b.master[rightSource + pos]
                if let left { left[i] += (monoSum ? (l + r) * 0.5 : l) * gain }
                if let right { right[i] += r * gain }
                if let tc, let t = b.timecode { tc[i] += t[pos] * timecodeGain }
            }
            gain = max(0, gain - rampStep)
            pos += 1
            i += 1
        }
        return pos
    }
}

/// What the audio thread is playing: the song and where it is, the song it runs straight into
/// when this one ends (nil: it plays on into silence), and the song it was just cut away from,
/// crossfading out on the master so the cut doesn't click.
public struct Playhead {
    public var buffers: PlaybackBuffers?
    public var position: Int
    public var next: PlaybackBuffers?
    /// Counts each time the playhead ran on into `next`.
    public var advances: Int = 0
    var tail: PlaybackBuffers?
    var tailPosition = 0
    var fadeLeft = 0
    var fadeLength = 0

    public init(buffers: PlaybackBuffers? = nil, position: Int = 0, next: PlaybackBuffers? = nil) {
        self.buffers = buffers
        self.position = position
        self.next = next
    }

    /// Switches to `buffers` at `position` at once. With `fade` frames, the master crossfades
    /// from what was playing instead of cutting dead; the timecode switches on the first sample.
    public mutating func cut(to buffers: PlaybackBuffers?, at position: Int, fade: Int) {
        if fade > 0, let old = self.buffers, self.position >= 0, self.position < old.frameCount {
            tail = old
            tailPosition = self.position
            fadeLength = fade
            fadeLeft = fade
        } else if fade <= 0 {
            tail = nil
            fadeLeft = 0
        }
        self.buffers = buffers
        self.position = position
        next = nil
    }

    /// True while the song cut away from is still fading out.
    public var isFading: Bool { fadeLeft > 0 && tail != nil }

    /// Drops what's left of a fade (on stop, so it never sounds when play resumes).
    public mutating func endFade() {
        tail = nil
        fadeLeft = 0
    }
}

extension Mixer {
    /// The fade under a cut: long enough not to click, short enough to feel instant.
    public static func cutFadeFrames(sampleRate: Double) -> Int { max(1, Int(sampleRate * 0.008)) }
}

extension PlaybackBuffers {
    /// Builds a song's buffers. With no timecode file, the timecode is generated from the
    /// sheet: the frame that reads `song.start` begins exactly `song.fileOffset` seconds into
    /// the master. The caller shows that it's generated; it's never silent.
    ///
    /// A song with a timecode file never gets generated timecode: if the file couldn't be read
    /// (`timecodeFileProblem`), no timecode is sent and the problem is shown instead.
    public static func prepare(song: Song, sampleRate: Double, master: [[Float]], timecode: [Float]?,
                               timecodeFile: String? = nil, timecodeFileProblem: String? = nil) -> PlaybackBuffers {
        if let timecode {
            let track = LTCTrack(samples: timecode, sampleRate: sampleRate, expectedRate: song.rate)
            return PlaybackBuffers(sampleRate: sampleRate, master: master, timecode: timecode,
                                   source: .file(timecodeFile ?? ""), ltc: track)
        }
        if let problem = timecodeFileProblem {
            return PlaybackBuffers(sampleRate: sampleRate, master: master, timecode: nil, source: .unreadable(problem), ltc: nil)
        }
        if !song.hasTimecode { return PlaybackBuffers(sampleRate: sampleRate, master: master, timecode: nil, source: .none, ltc: nil) }
        let frames = master.map(\.count).max() ?? 0
        return PlaybackBuffers(sampleRate: sampleRate, master: master,
                               timecode: generatedTimecode(for: song, sampleRate: sampleRate, frames: frames),
                               source: .generated, ltc: nil)
    }

    public static func generatedTimecode(for song: Song, sampleRate: Double, frames: Int) -> [Float] {
        let fps = song.rate.framesPerSecond
        // The last frame boundary at or before the start of the file.
        let k = -Int((song.fileOffset * fps).rounded(.up))
        let boundary = song.fileOffset + Double(k) / fps          // ≤ 0, in seconds
        let skip = Int((-boundary * sampleRate).rounded())
        let needed = Int((Double(frames + skip) / sampleRate * fps).rounded(.up)) + 1
        let ltc = LTC.render(start: song.start.adding(frames: k), frameCount: max(1, needed), sampleRate: sampleRate)
        let slice = ltc.dropFirst(skip).prefix(frames)
        return Array(slice) + [Float](repeating: 0, count: max(0, frames - slice.count))
    }
}
