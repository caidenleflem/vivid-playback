import SwiftUI
import PlaybackCore

/// Reads the audio thread's peak levels 30 times a second, with smooth fall-off and a held peak.
@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var levels = [Float](repeating: 0, count: 64)
    @Published private(set) var holds = [Float](repeating: 0, count: 64)
    private var holdTimes = [Double](repeating: 0, count: 64)
    private var timer: Timer?
    private let state: RenderState

    init(state: RenderState) {
        self.state = state
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
    }

    private func read() {
        let now = Date().timeIntervalSinceReferenceDate
        var l = levels, h = holds
        var changed = false
        for c in 0..<64 {
            let raw = state.peaks[c]
            state.peaks[c] = 0
            let v = Self.position(raw)
            let fallen = max(v, l[c] - 0.04)
            if fallen != l[c] { l[c] = fallen; changed = true }
            if v >= h[c] { h[c] = v; holdTimes[c] = now; changed = true }
            else if now - holdTimes[c] > 1.5, h[c] > 0 { h[c] = max(0, h[c] - 0.03); changed = true }
        }
        if changed { levels = l; holds = h }
    }

    /// 0…1 on a -60…0 dB scale.
    static func position(_ peak: Float) -> Float {
        guard peak > 0.000_001 else { return 0 }
        let db = 20 * log10(peak)
        return max(0, min(1, (db + 60) / 60))
    }
}

/// A slim horizontal level meter: green, then gold above -12 dB, red above -3 dB, with a peak tick.
struct LevelMeter: View {
    var level: Float
    var hold: Float
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                LinearGradient(stops: [
                    .init(color: Brand.ok, location: 0),
                    .init(color: Brand.ok, location: 0.76),
                    .init(color: Brand.gold, location: 0.82),
                    .init(color: Color(hex: 0xE5675A), location: 0.97),
                ], startPoint: .leading, endPoint: .trailing)
                .mask(alignment: .leading) { Capsule().frame(width: w * CGFloat(level)) }
                if hold > 0.01 {
                    Capsule().fill(hold > 0.95 ? Color(hex: 0xE5675A) : Brand.ink.opacity(0.85))
                        .frame(width: 2)
                        .offset(x: max(0, w * CGFloat(hold) - 2))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(level * 60 - 60)) dB")
    }
}

/// A labelled meter row for one output.
struct ChannelMeter: View {
    @EnvironmentObject private var meters: MeterModel
    let label: String
    let channel: Int?   // 0-based

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.manrope(11, .semibold)).foregroundStyle(Brand.space).frame(width: 64, alignment: .leading)
            if let c = channel, c < 64 {
                LevelMeter(level: meters.levels[c], hold: meters.holds[c])
            } else {
                Capsule().fill(.white.opacity(0.04)).frame(height: 6)
            }
        }
    }
}
