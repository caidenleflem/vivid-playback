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
                // Show TC is what's actually going out (the file's own LTC when there is one).
                let tc = (songTime || !song.hasTimecode)
                    ? Timecode(frameCount: Int(max(0, position) * song.rate.framesPerSecond), rate: song.rate)
                    : transport.outputTimecode(for: song)
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
    @EnvironmentObject private var control: ControlCenter

    var body: some View {
        HStack(spacing: 8) {
            Chip(transport.isPlaying ? "Rolling" : "Stopped") {
                StatusDot(color: transport.isPlaying ? Brand.gold : Brand.graphite, pulsing: transport.isPlaying)
            }
            if let song = model.currentSong, song.hasTimecode { Chip(song.rate.displayName) }
            if let song = model.currentSong, !song.hasTimecode {
                Chip("No timecode for this song · song time") { StatusDot(color: Brand.graphite) }
            } else {
                outputChip
            }
            if control.isFollowing {
                Chip("Following \(control.settings.follow.label)") {
                    StatusDot(color: control.followStatus.hasPrefix("Following") ? Brand.ok : Brand.warn,
                              pulsing: control.followStatus.hasPrefix("Following"))
                }
                .help(control.followStatus)
            }
            if let problem = transport.masterProblem {
                Chip("Master can't be read") { StatusDot(color: Color(hex: 0xE5675A)) }.help(problem)
            }
            if transport.loop != nil { Chip("Looping") { Image(systemName: "repeat").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.gold) } }
            if model.locked { Chip("Show mode") { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Brand.gold) } }
        }
    }

    private var sourceLabel: String {
        switch transport.source {
        case .file: return "Timecode out · from file"
        case .generated: return "Timecode out · generated from the sheet"
        default: return "Timecode out"
        }
    }

    private var sourceHelp: String {
        switch transport.source {
        case .file(let name): return "Playing the timecode in \(name). The clock shows the timecode read from that file."
        case .generated: return "This song has no timecode file, so timecode is generated from the sheet's start."
        default: return "Timecode is going out on its own output."
        }
    }

    @ViewBuilder private var outputChip: some View {
        switch transport.status {
        case .playing, .lost:
            if !transport.audio.isRunning {
                Chip("No audio output") { StatusDot(color: Color(hex: 0xE5675A)) }
            } else if case .unreadable(let why) = transport.source {
                Button { model.issuesShown = true } label: {
                    Chip("Timecode file can't be read · no timecode sent") { StatusDot(color: Color(hex: 0xE5675A)) }
                }
                .buttonStyle(.plain)
                .help(why)
            } else if case .file(let name) = transport.source, !transport.trackFound, !transport.isLoading {
                Chip("No timecode found in \(name)") { StatusDot(color: Color(hex: 0xE5675A)) }
                    .help("The file plays, but there's no readable LTC in it. Check it's the right file.")
            } else if transport.timecodeRouted {
                Chip(sourceLabel) {
                    StatusDot(color: transport.isPlaying ? Brand.ok : Brand.graphite, pulsing: transport.isPlaying)
                }
                .help(sourceHelp)
            } else {
                Button { model.outputShown = true } label: {
                    Chip("Choose a timecode output") { StatusDot(color: Brand.warn) }
                }
                .buttonStyle(.plain)
            }
        case .clockOnly(let why):
            Button { model.outputShown = true } label: {
                Chip("Clock only · \(why)") { StatusDot(color: Brand.graphite) }
            }
            .buttonStyle(.plain)
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
                    if let song = model.currentSong {
                        Text(song.title)
                            .font(.manrope(30, .semibold))
                            .foregroundStyle(Brand.ink)
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
