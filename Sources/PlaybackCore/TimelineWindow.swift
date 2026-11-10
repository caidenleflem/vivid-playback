import Foundation

/// The stretch of a song the timeline shows: the whole song at zoom 1, a smaller span when
/// zoomed in. Pure maths for the view: seconds ↔ points, zooming around a point, panning,
/// keeping the playhead in view, and ruler spacing.
public struct TimelineWindow: Equatable, Sendable {
    public static let maxZoom: Double = 200

    /// The song's length in seconds.
    public var length: Double
    /// 1 shows the whole song; 2 shows half of it.
    public private(set) var zoom: Double
    /// The time at the left edge, in seconds.
    public private(set) var start: Double

    public init(length: Double, zoom: Double = 1, start: Double = 0) {
        self.length = max(0.001, length)
        self.zoom = 1
        self.start = 0
        setZoom(zoom, around: start)
        self.start = clampStart(start)
    }

    public var span: Double { length / zoom }
    public var end: Double { start + span }
    public var isZoomed: Bool { zoom > 1.0001 }

    public func x(_ seconds: Double, width: Double) -> Double { (seconds - start) / span * width }
    public func time(atX x: Double, width: Double) -> Double { start + x / max(width, 1) * span }
    public func contains(_ seconds: Double) -> Bool { seconds >= start && seconds <= end }

    /// Zooms so that `anchor` (a time) stays where it is on screen.
    public mutating func setZoom(_ newZoom: Double, around anchor: Double) {
        let z = min(Self.maxZoom, max(1, newZoom))
        let fraction = span > 0 ? (anchor - start) / span : 0.5
        zoom = z
        start = clampStart(anchor - fraction * span)
    }

    public mutating func zoom(by factor: Double, around anchor: Double) { setZoom(zoom * factor, around: anchor) }

    public mutating func pan(by seconds: Double) { start = clampStart(start + seconds) }

    public mutating func fit() { zoom = 1; start = 0 }

    /// Pages along so the playhead stays in view while playing: when it reaches 90% of the
    /// way across, it moves back to 10%. A playhead outside the window centres it.
    public mutating func follow(_ playhead: Double) {
        guard isZoomed else { return }
        if playhead < start || playhead > end {
            start = clampStart(playhead - span / 2)
        } else if playhead > start + span * 0.9 {
            start = clampStart(playhead - span * 0.1)
        }
    }

    /// Seconds between labelled ticks, so labels sit at least `minSpacing` points apart.
    public func tickStep(width: Double, minSpacing: Double = 90, fps: Double = 30) -> Double {
        let frame = 1 / max(fps, 1)
        let steps = [frame, 2 * frame, 5 * frame, 10 * frame, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let perSecond = width / max(span, 0.0001)
        return steps.first { $0 * perSecond >= minSpacing } ?? 600
    }

    private func clampStart(_ s: Double) -> Double { min(max(0, s), max(0, length - span)) }
}
