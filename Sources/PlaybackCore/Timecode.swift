import Foundation

/// The frame rates a show can run at. Pull-down rates (23.976, 29.97) run 0.1% slower than their
/// labels; drop-frame (29.97 DF) skips frame labels so the clock stays on real time.
public enum FrameRate: String, Codable, CaseIterable, Sendable, Hashable {
    case fps23_976 = "23.976"
    case fps24 = "24"
    case fps25 = "25"
    case fps29_97 = "29.97"
    case fps29_97DF = "29.97DF"
    case fps30 = "30"

    /// Frames per second as counted in the label (24, 25 or 30).
    public var nominalFPS: Int {
        switch self {
        case .fps23_976, .fps24: return 24
        case .fps25: return 25
        case .fps29_97, .fps29_97DF, .fps30: return 30
        }
    }

    public var isDropFrame: Bool { self == .fps29_97DF }
    public var isPullDown: Bool { self == .fps23_976 || self == .fps29_97 || self == .fps29_97DF }

    /// Real frames per second.
    public var framesPerSecond: Double {
        isPullDown ? Double(nominalFPS) * 1000.0 / 1001.0 : Double(nominalFPS)
    }

    public var displayName: String {
        switch self {
        case .fps23_976: return "23.976 fps"
        case .fps24: return "24 fps"
        case .fps25: return "25 fps"
        case .fps29_97: return "29.97 fps"
        case .fps29_97DF: return "29.97 DF"
        case .fps30: return "30 fps"
        }
    }

    /// Short label for badges ("30", "29.97 DF").
    public var shortName: String {
        switch self {
        case .fps29_97DF: return "29.97 DF"
        default: return rawValue
        }
    }

    /// Frame labels in one day (00:00:00:00 up to, not including, 24:00:00:00).
    public var framesPerDay: Int {
        isDropFrame ? 24 * 6 * Timecode.dfFramesPer10Minutes : nominalFPS * 86_400
    }

    /// Reads the ways rates are written on offset sheets: "30", "30 fps", "29.97 DF", "29.97df",
    /// "2997", "23.98", "23.976", "25fps", "30 DF" (read as 29.97 drop-frame, as consoles do).
    public static func parse(_ text: String) -> FrameRate? {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let nonDrop = s.contains("ndf") || s.contains("non")
        let drop = !nonDrop && (s.contains("df") || s.contains("drop"))
        s = String(s.filter { $0.isNumber || $0 == "." || $0 == "," }).replacingOccurrences(of: ",", with: ".")
        switch s {
        case "23.976", "23.98", "23.97", "2398", "23976": return .fps23_976
        case "24", "24.0", "24.00": return .fps24
        case "25", "25.0", "25.00": return .fps25
        case "29.97", "2997", "29.970": return drop ? .fps29_97DF : .fps29_97
        case "30", "30.0", "30.00": return drop ? .fps29_97DF : .fps30
        default: return nil
        }
    }

    /// The rate whose real speed is closest to `fps`, given the label's nominal rate and drop flag.
    public static func closest(toMeasured fps: Double, nominal: Int, dropFrame: Bool) -> FrameRate {
        if nominal == 30 && dropFrame { return .fps29_97DF }
        let candidates = FrameRate.allCases.filter { $0.nominalFPS == nominal && !$0.isDropFrame }
        return candidates.min(by: { abs($0.framesPerSecond - fps) < abs($1.framesPerSecond - fps) }) ?? .fps30
    }
}

/// A timecode label at a given rate, stored as a frame count since 00:00:00:00.
/// For drop-frame, the count is of real frames, so `seconds` is always real time.
public struct Timecode: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let frameCount: Int
    public let rate: FrameRate

    static let dfFramesPerMinute = 30 * 60 - 2         // 1798
    static let dfFramesPer10Minutes = 30 * 600 - 18    // 17982

    public init(frameCount: Int, rate: FrameRate) {
        let day = rate.framesPerDay
        self.frameCount = ((frameCount % day) + day) % day
        self.rate = rate
    }

    /// Builds a timecode from its parts. Returns nil for parts out of range, and for drop-frame
    /// labels that don't exist (frames 00 and 01 of each minute except every tenth).
    public init?(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: FrameRate) {
        guard (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds),
              (0..<rate.nominalFPS).contains(frames) else { return nil }
        if rate.isDropFrame {
            if seconds == 0 && frames < 2 && minutes % 10 != 0 { return nil }
            let totalMinutes = 60 * hours + minutes
            let count = (hours * 3600 + minutes * 60 + seconds) * 30 + frames - 2 * (totalMinutes - totalMinutes / 10)
            self.init(frameCount: count, rate: rate)
        } else {
            let count = (hours * 3600 + minutes * 60 + seconds) * rate.nominalFPS + frames
            self.init(frameCount: count, rate: rate)
        }
    }

    /// Parses "HH:MM:SS:FF", "HH:MM:SS;FF", "HH.MM.SS.FF" or "HH:MM:SS" (frames 00).
    public init?(_ text: String, rate: FrameRate) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." || $0 == "," })
        guard parts.count == 3 || parts.count == 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 2, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        if numbers.count == 3 { numbers.append(0) }
        self.init(hours: numbers[0], minutes: numbers[1], seconds: numbers[2], frames: numbers[3], rate: rate)
    }

    /// The timecode of the frame playing at `seconds` of real time since 00:00:00:00.
    public init(seconds: Double, rate: FrameRate) {
        self.init(frameCount: Int((seconds * rate.framesPerSecond + 1e-6).rounded(.down)), rate: rate)
    }

    public var components: (hours: Int, minutes: Int, seconds: Int, frames: Int) {
        var label = frameCount
        let fps = rate.nominalFPS
        if rate.isDropFrame {
            let tens = frameCount / Self.dfFramesPer10Minutes
            let rest = frameCount % Self.dfFramesPer10Minutes
            label += 18 * tens
            if rest > 1 { label += 2 * ((rest - 2) / Self.dfFramesPerMinute) }
        }
        let frames = label % fps
        let totalSeconds = label / fps
        return (totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, frames)
    }

    /// Real time since 00:00:00:00, in seconds.
    public var seconds: Double { Double(frameCount) / rate.framesPerSecond }

    public var description: String {
        let c = components
        let last = rate.isDropFrame ? ";" : ":"
        return "\(Self.two(c.hours)):\(Self.two(c.minutes)):\(Self.two(c.seconds))\(last)\(Self.two(c.frames))"
    }

    static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)"
    }

    public func adding(frames: Int) -> Timecode { Timecode(frameCount: frameCount + frames, rate: rate) }

    /// Signed frame distance from `other` to `self` (same rate assumed), the short way round midnight.
    public func frames(since other: Timecode) -> Int {
        let day = rate.framesPerDay
        var d = frameCount - other.frameCount
        if d > day / 2 { d -= day } else if d < -day / 2 { d += day }
        return d
    }

    public static func < (lhs: Timecode, rhs: Timecode) -> Bool { lhs.frameCount < rhs.frameCount }
}

extension Timecode: Codable {
    private enum CodingKeys: String, CodingKey { case timecode, rate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rate = try c.decode(FrameRate.self, forKey: .rate)
        let text = try c.decode(String.self, forKey: .timecode)
        guard let tc = Timecode(text, rate: rate) else {
            throw DecodingError.dataCorruptedError(forKey: .timecode, in: c, debugDescription: "Not a timecode: \(text)")
        }
        self = tc
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(description, forKey: .timecode)
        try c.encode(rate, forKey: .rate)
    }
}

public enum TimeFormat {
    /// "4:31" or "1:04:31".
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Reads a duration: "4:31", "04:31.5", "1:02:03", "271.5", "271.5 s".
    public static func parseDuration(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "sec", with: "").replacingOccurrences(of: "s", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":")
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0 else { return nil }
            if i < parts.count - 1 && p.contains(".") { return nil }
            total = total * 60 + v
        }
        return total
    }
}
