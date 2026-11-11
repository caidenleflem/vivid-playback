import SwiftUI
import AppKit
import PlaybackCore

/// The full-screen player: Apple Music's Now Playing, for the show. Big artwork, the song, a
/// scrubber, the transport and the timecode, with Up Next beside it. No timeline vocabulary.
struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    /// Up Next starts folded to the next song, floating in the corner, with the player centred
    /// in the window. Unfolded, it takes a column and the player moves over to make room.
    @State private var upNextExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // The artwork takes what's left after the controls, so nothing is cut off at the bottom.
            let wide = geo.size.width >= 940
            let column = wide && upNextExpanded
            let stage = column ? geo.size.width - 330 : geo.size.width
            let art = max(150, min(geo.size.height - 470, stage * 0.5, 460))
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                ZStack(alignment: .topTrailing) {
                    HStack(alignment: .top, spacing: 0) {
                        Group {
                            if let song = model.currentSong {
                                nowPlaying(song, art: art)
                            } else {
                                Text("Nothing cued").font(.manrope(18, .semibold)).foregroundStyle(Brand.space)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Room for the unfolded queue; folded, the player has the whole width.
                        if column { Color.clear.frame(width: 322) }
                    }
                    if wide {
                        UpNextPanel(expanded: $upNextExpanded)
                            .frame(width: 300)
                            .padding(.trailing, 22)
                            .padding(.vertical, 18)
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .vivid(0.4), value: upNextExpanded)
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64, height: 1)  // room for the window buttons
            Button { model.go(.library) } label: {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(IconButtonStyle())
            .help("Back to the library (Esc)")
            Spacer()
            Button { model.go(.timeline) } label: {
                Label("Timeline", systemImage: "arrow.up.left.and.arrow.down.right").font(.manrope(11.5, .semibold))
            }
            .buttonStyle(QuietButtonStyle())
            .help("Open the song timeline (Return)")
            Button { model.go(.clock) } label: { Image(systemName: "clock").font(.system(size: 14)) }
                .buttonStyle(IconButtonStyle())
                .help("Full-screen clock (⇧⌘F)")
        }
        .frame(height: 44)
    }

    // MARK: Now playing

    private func nowPlaying(_ song: Song, art: CGFloat) -> some View {
        let q = model.queue
        let index = (q.firstIndex { $0.id == song.id } ?? 0) + 1
        let width = min(max(art * 1.25, 420), 600)
        return VStack(spacing: 0) {
            Spacer(minLength: 8)
            artwork(song)
                .frame(width: art, height: art)
                .shadow(color: .black.opacity(0.55), radius: 40, y: 26)
                .scaleEffect(transport.isPlaying ? 1 : 0.94)
                .animation(.vivid(0.5), value: transport.isPlaying)
                .id(song.id)
                .transition(.opacity)
            Spacer(minLength: 20).frame(maxHeight: 36)

            VStack(spacing: 6) {
                Text(song.title)
                    .font(.manrope(30, .bold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(subtitle(index: index, of: q.count))
                    .font(.manrope(15, .medium))
                    .foregroundStyle(Brand.steel)
                    .lineLimit(1)
            }
            .frame(width: width)

            Scrubber()
                .frame(width: width)
                .padding(.top, 22)

            TransportControls()
                .padding(.top, 14)

            LiveClock(size: 22, weight: .regular)
                .padding(.top, 14)

            ExtrasRow()
                .padding(.top, 18)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 24)
        .animation(.vivid(0.35), value: song.id)
    }

    @ViewBuilder private func artwork(_ song: Song) -> some View {
        if let list = model.setlist, list.artwork != nil {
            AlbumCover(setlist: list, package: model.packageURL, cornerRadius: 14)
        } else {
            SongArt(song: song, cornerRadius: 14)
        }
    }

    private func subtitle(index: Int, of count: Int) -> String {
        var parts: [String] = []
        if let artist = model.show?.artist, !artist.isEmpty { parts.append(artist) }
        parts.append(model.setlist?.name ?? model.show?.name ?? "")
        parts.append("Song \(index) of \(count)")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: Scrubber

/// The song's progress, draggable: drag to find a spot, let go to locate there.
private struct Scrubber: View {
    @EnvironmentObject private var transport: Transport
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        SongProgress(rate: 20) { position, length in
            let start = transport.lowerBound
            let span = max(0.001, length - start)
            let fraction = dragging ?? min(1, max(0, (position - start) / span))
            VStack(spacing: 6) {
                GeometryReader { g in
                    let thick: CGFloat = hovering || dragging != nil ? 7 : 5
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16)).frame(height: thick)
                        Capsule().fill(Brand.ink.opacity(0.92)).frame(width: max(thick, g.size.width * fraction), height: thick)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragging = min(1, max(0, Double(v.location.x / max(g.size.width, 1)))) }
                        .onEnded { v in
                            let f = min(1, max(0, Double(v.location.x / max(g.size.width, 1))))
                            transport.locate(start + f * span)
                            dragging = nil
                        })
                    .animation(.vivid(0.2), value: thick)
                }
                .frame(height: 16)
                .onHover { hovering = $0 }
                HStack {
                    Text(TimeFormat.clock(max(0, start + fraction * span)))
                    Spacer()
                    Text("−" + TimeFormat.clock(max(0, length - (start + fraction * span))))
                }
                .font(.manrope(12, .medium).monospacedDigit())
                .foregroundStyle(Brand.space)
            }
        }
    }
}

// MARK: Transport

private struct TransportControls: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport

    var body: some View {
        HStack(spacing: 34) {
            Button { model.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 26, weight: .medium))
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .help("Previous song (←)")
            Button { transport.toggle() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x120D05))
                    .offset(x: transport.isPlaying ? 0 : 2)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Brand.gold))
                    .shadow(color: Brand.gold.opacity(transport.isPlaying ? 0.35 : 0), radius: 18)
                    .contentShape(Circle())
            }
            .help("Play or pause (Space)")
            Button { model.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 26, weight: .medium))
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .help("Next song (→)")
        }
        .buttonStyle(PressButtonStyle())
        .foregroundStyle(Brand.ink)
        .animation(.vivid(0.25), value: transport.isPlaying)
    }
}

/// Shrinks a touch while pressed, like Apple Music's controls.
private struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.vivid(0.18), value: configuration.isPressed)
    }
}

// MARK: Extras

/// Loop, stop after each song, and where the timecode comes from: small and quiet.
private struct ExtrasRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport

    var body: some View {
        HStack(spacing: 8) {
            toggle("repeat", "Loop", on: transport.loop != nil) { model.toggleLoop() }
                .help("Loop between the markers either side of the playhead, or the whole song (L)")
            toggle("stop.circle", "Stop after each", on: model.stopAfterEach) { model.stopAfterEach.toggle() }
                .help("Stop at the end of each song instead of going on to the next")
            StateChips()
        }
    }

    private func toggle(_ symbol: String, _ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                Text(title).font(.manrope(12, .semibold))
            }
            .foregroundStyle(on ? Color(hex: 0x120D05) : Brand.steel)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(on ? Brand.gold : .white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Up Next

/// What plays after this song, in setlist order. A solid list (lists are never glass).
/// What plays after this song, in setlist order. A solid list (lists are never glass). Starts
/// collapsed to just the next song; the chevron shows the rest of the set.
private struct UpNextPanel: View {
    @EnvironmentObject private var model: AppModel
    @Binding var expanded: Bool

    var body: some View {
        let q = model.queue
        let current = q.firstIndex { $0.id == model.currentSong?.id } ?? -1
        let upcoming = Array(q.enumerated()).filter { $0.offset > current }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard upcoming.count > 1 || expanded else { return }
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(expanded ? "Up Next" : "Next").font(.manrope(17, .bold)).foregroundStyle(Brand.ink)
                    if !expanded && upcoming.count > 1 {
                        Text("+\(upcoming.count - 1) more").font(.manrope(12, .medium)).foregroundStyle(Brand.space)
                    }
                    Spacer()
                    if expanded {
                        Text(model.setlist?.name ?? "").font(.manrope(12, .medium)).foregroundStyle(Brand.space).lineLimit(1)
                    }
                    if upcoming.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Brand.steel)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(upcoming.count > 1 ? (expanded ? "Show just the next song" : "Show the rest of the set") : "")
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if model.stopAfterEach && !upcoming.isEmpty {
                Label("Stops after this song", systemImage: "stop.circle")
                    .font(.manrope(11.5, .semibold)).foregroundStyle(Brand.gold)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if upcoming.isEmpty {
                Text("Last song of the set").font(.manrope(13)).foregroundStyle(Brand.space)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else if expanded {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(upcoming, id: \.element.id) { item in
                            UpNextRow(song: item.element, number: item.offset + 1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .transition(.opacity)
            } else if let next = upcoming.first {
                UpNextRow(song: next.element, number: next.offset + 1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: expanded ? .infinity : nil, alignment: .top)
        .solidPanel()
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct UpNextRow: View {
    @EnvironmentObject private var model: AppModel
    let song: Song
    let number: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Text("\(number)").font(.manrope(12, .semibold).monospacedDigit()).foregroundStyle(Brand.graphite)
                .frame(width: 20, alignment: .trailing)
            SongArt(song: song, cornerRadius: 5).frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.manrope(13.5, .semibold)).foregroundStyle(Brand.ink).lineLimit(1)
                Text(song.hasTimecode ? song.start.description : "No timecode")
                    .font(.manrope(11.5).monospacedDigit()).foregroundStyle(Brand.space)
            }
            Spacer(minLength: 4)
            if let length = song.playLength {
                Text(TimeFormat.clock(length)).font(.manrope(12).monospacedDigit()).foregroundStyle(Brand.space)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // Double-click plays it now (as in the song list); one click does nothing surprising.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.playFromList(song) }
        }
        .contextMenu {
            Button("Play Now") { model.playFromList(song) }
            Button("Cue This Song") { model.cue(song) }
        }
        .help("Double-click to play")
    }
}
