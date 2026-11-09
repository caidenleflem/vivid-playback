import SwiftUI
import QuartzCore
import PlaybackCore

/// HH:MM:SS:FF with every digit in a fixed-width cell, so nothing shifts as it counts.
struct ClockText: View {
    let timecode: Timecode?
    let size: CGFloat
    var weight: Font.Weight = .light
    var color: Color = Brand.ink

    var body: some View {
        let text = timecode?.description ?? "--:--:--:--"
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                if ch == ":" || ch == ";" {
                    Text(String(ch))
                        .foregroundStyle(Brand.graphite)
                        .frame(width: size * 0.3)
                } else {
                    Text(String(ch))
                        .foregroundStyle(color)
                        .frame(width: size * 0.6)
                }
            }
        }
        .font(.manrope(size, weight))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timecode.map { "Timecode \($0.description)" } ?? "No timecode")
    }
}

/// A clock that redraws every frame while rolling and stays still when stopped.
struct LiveClock: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    let size: CGFloat
    var weight: Font.Weight = .light
    /// Song time (elapsed) instead of show timecode.
    var songTime = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !transport.isPlaying)) { _ in
            let color = transport.isPlaying ? Brand.gold : Brand.ink
            if let song = model.currentSong {
                let position = transport.position(at: CACurrentMediaTime())
                let tc = songTime
                    ? Timecode(frameCount: Int(max(0, position) * song.rate.framesPerSecond), rate: song.rate)
                    : model.timecode(for: song, at: position)
                ClockText(timecode: tc, size: size, weight: weight, color: color)
            } else {
                ClockText(timecode: nil, size: size, weight: weight, color: Brand.graphite)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: transport.isPlaying)
    }
}

/// Elapsed and remaining for the current song, and a progress fraction.
struct SongProgress<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    @ViewBuilder var content: (_ position: Double, _ length: Double) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !transport.isPlaying)) { _ in
            let length = model.currentSong?.length ?? 0
            content(min(transport.position(at: CACurrentMediaTime()), max(length, 0)), length)
        }
    }
}

struct StateChips: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport

    var body: some View {
        HStack(spacing: 8) {
            Chip(transport.isPlaying ? "Rolling" : "Stopped") {
                StatusDot(color: transport.isPlaying ? Brand.gold : Brand.graphite, pulsing: transport.isPlaying)
            }
            if let song = model.currentSong { Chip(song.rate.displayName) }
            Chip("Preview · no audio yet") { StatusDot(color: Brand.graphite) }
                .help("This build runs the clock and the setlist. Master and timecode output come in the next build.")
        }
    }
}

/// The full-screen clock for a second monitor at front of house.
struct ClockScreen: View {
    @EnvironmentObject private var model: AppModel
    let morph: Namespace.ID

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 20) {
                    StateChips()
                    LiveClock(size: min(230, (geo.size.width - 96) / 5.7), weight: .light)
                        .matchedGeometryEffect(id: "clock", in: morph)
                    if let song = model.currentSong {
                        Text(song.title)
                            .font(.manrope(30, .semibold))
                            .foregroundStyle(Brand.ink)
                            .matchedGeometryEffect(id: "title", in: morph)
                        SongProgress { position, length in
                            Text(nextLine(position: position, length: length))
                                .font(.manrope(16).monospacedDigit())
                                .foregroundStyle(Brand.space)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 6) { KeyCap(key: "Esc"); Text("back to the library") }
                            .font(.manrope(12))
                            .foregroundStyle(Brand.graphite)
                            .padding(24)
                    }
                    SongProgress { position, length in
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.08))
                                Rectangle().fill(Brand.gold).frame(width: length > 0 ? bar.size.width * position / length : 0)
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.go(.library) }
    }

    private func nextLine(position: Double, length: Double) -> String {
        let q = model.queue
        let index = model.currentSong.flatMap { s in q.firstIndex { $0.id == s.id } }.map { $0 + 1 } ?? 0
        var line = "Song \(index) of \(q.count)"
        if let next = model.nextSong { line += " · Next: \(next.title) in \(TimeFormat.clock(max(0, length - position)))" }
        return line
    }
}
