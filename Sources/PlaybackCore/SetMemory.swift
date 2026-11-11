import Foundation

/// Which songs stay loaded so switching to them is instant. The whole set is kept ready in
/// memory when it fits: the song playing, then the rest of the set in order, then the songs
/// before it (nearest first), then the album's other songs.
public enum SetMemory {
    /// Song IDs, most needed first, each once.
    public static func order(queue: [UUID], all: [UUID], current: UUID?) -> [UUID] {
        var out: [UUID] = []
        var seen = Set<UUID>()
        func take(_ id: UUID) { if seen.insert(id).inserted { out.append(id) } }
        if let current { take(current) }
        if let current, let i = queue.firstIndex(of: current) {
            queue[(i + 1)...].forEach(take)
            queue[..<i].reversed().forEach(take)
        } else {
            queue.forEach(take)
        }
        all.forEach(take)
        return out
    }

    /// The songs that fit in `budget` bytes, taken in order. Stops at the first that doesn't fit,
    /// so what's ready is always a run from the playing song on, never a set with holes. The
    /// first song is always kept: it's the one playing.
    public static func fitting(_ order: [UUID], bytes: (UUID) -> Int, budget: Int) -> [UUID] {
        var out: [UUID] = []
        var used = 0
        for id in order {
            let b = bytes(id)
            if !out.isEmpty && used + b > budget { break }
            out.append(id)
            used += b
        }
        return out
    }

    /// Memory a song takes loaded: each master channel and the timecode, 32-bit, at the rate.
    public static func estimatedBytes(seconds: Double, sampleRate: Double, masterChannels: Int = 2, timecode: Bool = true) -> Int {
        Int(max(0, seconds) * sampleRate) * (max(1, min(2, masterChannels)) + (timecode ? 1 : 0)) * MemoryLayout<Float>.size
    }

    /// How much of the Mac's memory the set may use: half, which leaves the rest for macOS.
    public static func budget(physicalMemory: UInt64) -> Int {
        Int(min(physicalMemory / 2, UInt64(Int.max)))
    }
}

extension Song {
    /// Everything the loaded audio depends on. A song kept in memory is used only while this
    /// still matches, so a changed file, start, offset, rate or timecode channel is never played
    /// from an old copy.
    public struct AudioKey: Hashable, Sendable {
        var masterPath: String?
        var timecodePath: String?
        var timecodeOn: Bool
        var timecodeChannel: Int?
        var start: Timecode
        var fileOffset: Double
        /// Only when there are no files: the silence plays for the sheet's length.
        var silentLength: Double?
    }

    public var audioKey: AudioKey {
        AudioKey(masterPath: masterPath, timecodePath: timecodePath, timecodeOn: hasTimecode,
                 timecodeChannel: timecodeFileChannel, start: start, fileOffset: fileOffset,
                 silentLength: masterPath == nil && timecodePath == nil ? length : nil)
    }
}
