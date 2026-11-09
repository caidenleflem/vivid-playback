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
        func zeroBased(_ c: Int?) -> Int? {
            guard let c, c >= 1, c <= channelCount else { return nil }
            return c - 1
        }
        self.channelCount = channelCount
        masterLeft = zeroBased(routing.masterChannels.first)
        masterRight = routing.masterChannels.count > 1 ? zeroBased(routing.masterChannels[1]) : nil
        timecode = zeroBased(routing.timecodeChannel)
        // Timecode never shares a channel with the master.
        if let t = timecode, t == masterLeft || t == masterRight { timecode = nil }
    }
}

/// One song's audio, ready to play: the master (one or two channels) and the timecode track,
/// at the interface's sample rate, sample-aligned (sample n of each belongs together).
/// Allocated once when the song is loaded; the realtime thread only reads it.
public final class PlaybackBuffers: @unchecked Sendable {
    public let sampleRate: Double
    public let frameCount: Int
    public let masterChannels: Int
    let master: UnsafeMutablePointer<Float>   // channel-major: [ch0 frames][ch1 frames]
    let timecode: UnsafeMutablePointer<Float>?
    /// True when the timecode was generated from the sheet rather than read from a file.
    public let timecodeGenerated: Bool

    public init(sampleRate: Double, master: [[Float]], timecode: [Float]?, timecodeGenerated: Bool = false) {
        self.sampleRate = sampleRate
        let channels = Array(master.prefix(2))
        let frames = max(channels.map(\.count).max() ?? 0, timecode?.count ?? 0)
        self.frameCount = frames
        self.masterChannels = max(1, channels.count)
        self.timecodeGenerated = timecodeGenerated
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
        guard let b = buffers else { return position }
        let left = map.masterLeft.flatMap { $0 < outputs.count ? outputs[$0] : nil }
        let right = map.masterRight.flatMap { $0 < outputs.count ? outputs[$0] : nil }
        let tc = map.timecode.flatMap { $0 < outputs.count ? outputs[$0] : nil }
        let rightSource = b.masterChannels > 1 ? b.frameCount : 0
        // The master on a single output (a two-output laptop: music left, timecode right) is
        // summed to mono so nothing is lost.
        let monoSum = right == nil && b.masterChannels > 1
        var pos = position
        var i = 0
        while i < frames {
            if let loop, loop.end > loop.start, pos >= loop.end { pos = loop.start }
            if pos >= 0 && pos < b.frameCount {
                let l = b.master[pos]
                let r = b.master[rightSource + pos]
                if let left { left[i] = (monoSum ? (l + r) * 0.5 : l) * masterGain }
                if let right { right[i] = r * masterGain }
                if let tc, let t = b.timecode { tc[i] = t[pos] * timecodeGain }
            }
            pos += 1
            i += 1
        }
        return pos
    }
}

extension PlaybackBuffers {
    /// Builds a song's buffers. With no timecode file, the timecode is generated from the
    /// sheet: the frame that reads `song.start` begins exactly `song.fileOffset` seconds into
    /// the master. The caller shows that it's generated; it's never silent.
    public static func prepare(song: Song, sampleRate: Double, master: [[Float]], timecode: [Float]?) -> PlaybackBuffers {
        if let timecode { return PlaybackBuffers(sampleRate: sampleRate, master: master, timecode: timecode) }
        if !song.hasTimecode { return PlaybackBuffers(sampleRate: sampleRate, master: master, timecode: nil) }
        let frames = master.map(\.count).max() ?? 0
        return PlaybackBuffers(sampleRate: sampleRate, master: master,
                               timecode: generatedTimecode(for: song, sampleRate: sampleRate, frames: frames),
                               timecodeGenerated: true)
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
