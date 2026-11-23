import SwiftUI
import PlaybackCore

/// Reads the audio thread's peak levels 60 times a second. Up at once, down at a steady rate,
/// with a held peak; between audio blocks (a joined or Dante device can deliver audio in big,
/// uneven blocks) the meters hold still instead of dipping.
@MainActor
final class MeterModel: ObservableObject {
    /// Levels and held peaks together, so each refresh is one update, not two.
    struct Snapshot: Equatable {
        var levels = [Float](repeating: 0, count: 64)
        var holds = [Float](repeating: 0, count: 64)
    }
    @Published private(set) var snapshot = Snapshot()
    var levels: [Float] { snapshot.levels }
    var holds: [Float] { snapshot.holds }
    private var meters = [MeterBallistics](repeating: MeterBallistics(), count: 64)
    private var lastBlocks = 0
    private var timer: Timer?
    private let state: RenderState

    init(state: RenderState) {
        self.state = state
        // 30 a second is as smooth as a meter needs to look, and half the redraws of 60.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func read() {
        let now = Date().timeIntervalSinceReferenceDate
        let blocks = state.blocks
        let fresh = blocks != lastBlocks
        lastBlocks = blocks
        // Nothing playing and the meters already at rest: nothing to redraw.
        if !fresh && snapshot.levels.allSatisfy({ $0 == 0 }) && snapshot.holds.allSatisfy({ $0 == 0 }) { return }
        var next = snapshot
        for c in 0..<64 {
            var raw: Float = 0
            if fresh {
                raw = state.peaks[c]
                state.peaks[c] = 0
            }
            meters[c].update(peak: raw, fresh: fresh, now: now)
            next.levels[c] = meters[c].level
            next.holds[c] = meters[c].hold
        }
        if next != snapshot { snapshot = next }
    }

    /// 0…1 on a -60…0 dB scale.
    static func position(_ peak: Float) -> Float { MeterBallistics.position(peak) }
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
