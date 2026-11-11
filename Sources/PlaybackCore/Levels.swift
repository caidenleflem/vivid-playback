import Foundation

/// How a level meter moves: up at once, down at a steady rate, a peak held for a moment. It
/// only falls when there's new audio to show, so a device that delivers audio in big or uneven
/// blocks doesn't make the meter flicker.
public struct MeterBallistics: Equatable, Sendable {
    /// 0…1 on the meter's scale.
    public private(set) var level: Float = 0
    public private(set) var hold: Float = 0
    private var holdSince: Double = 0
    private var last: Double?

    /// The meter's scale (0…1) per second it falls.
    public static let fallPerSecond: Float = 0.4      // 24 dB a second on a 60 dB meter
    public static let holdSeconds: Double = 1.5
    public static let holdFallPerSecond: Float = 0.9

    public init() {}

    /// `peak` is the loudest sample since the last update (linear), `fresh` whether any audio
    /// was rendered since then.
    public mutating func update(peak: Float, fresh: Bool, now: Double) {
        let dt = Float(max(0, min(0.25, now - (last ?? now))))
        last = now
        guard fresh else { return }
        let v = Self.position(peak)
        level = max(v, level - Self.fallPerSecond * dt)
        if v >= hold {
            hold = v
            holdSince = now
        } else if now - holdSince > Self.holdSeconds {
            hold = max(level, hold - Self.holdFallPerSecond * dt)
        }
    }

    /// 0…1 on a -60…0 dB scale.
    public static func position(_ peak: Float) -> Float {
        guard peak > 0.000_001 else { return 0 }
        let db = 20 * log10(peak)
        return max(0, min(1, (db + 60) / 60))
    }
}

extension Mixer {
    /// Above this the master limiter starts to bend the level down.
    public static let limiterKnee: Float = 0.89   // -1 dBFS

    /// Keeps a boosted master from clipping: untouched up to -1 dBFS, then bent smoothly so it
    /// never passes full scale. Only ever used on the master, never on timecode.
    @inline(__always)
    public static func limit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > limiterKnee else { return x }
        let room = 1 - limiterKnee
        let y = limiterKnee + room * Float(tanh(Double((a - limiterKnee) / room)))
        return x < 0 ? -y : y
    }

    /// Limits `frames` samples of one output in place.
    public static func limit(_ p: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames { p[i] = limit(p[i]) }
    }
}
