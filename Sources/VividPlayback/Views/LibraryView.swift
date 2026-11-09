import SwiftUI
import AppKit
import PlaybackCore

enum BrandImage {
    static let emblem: NSImage? = {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Images/emblem-gold.png")) }
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Images/emblem-gold.png"))
        return candidates.lazy.compactMap { NSImage(contentsOf: $0) }.first
    }()
}

struct Emblem: View {
    var width: CGFloat
    var body: some View {
        if let image = BrandImage.emblem {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: width)
                .accessibilityHidden(true)
        }
    }
}

struct LibraryView: View {
    let morph: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 224)
                .padding(10)
                .transition(.move(edge: .leading).combined(with: .opacity))
            VStack(spacing: 0) {
                PlayerBar(morph: morph)
                    .padding(.top, 12)
                ClockHero(morph: morph)
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                SongList()
                    .transition(.opacity.combined(with: .offset(y: 40)))
                    .padding(.bottom, 12)
            }
            .padding(.trailing, 14)
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Emblem(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.show?.name ?? "No show").font(.manrope(13, .bold)).foregroundStyle(Brand.ink).lineLimit(1)
                    Text("\(model.show?.songs.count ?? 0) songs · \(model.show?.defaultRate.displayName ?? "")")
                        .font(.manrope(11.5)).foregroundStyle(Brand.space)
                }
            }
            .padding(.horizontal, 8)

            section("Setlists") {
                ForEach(model.show?.setlists ?? []) { list in
                    navRow(list.name, selected: model.setlist?.id == list.id) {
                        model.selectedSetlistID = list.id
                    }
                }
            }

            section("Check") {
                navRow("Issues", selected: false, badge: model.issues.isEmpty ? nil : model.issues.count) {
                    model.issuesShown = true
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { StatusDot(color: Brand.graphite); Text("Master · Out \(channels(model.show?.routing.masterChannels ?? [1, 2]))") }
                HStack(spacing: 8) {
                    StatusDot(color: Brand.graphite)
                    Text(model.show?.routing.timecodeChannel.map { "Timecode · Out \($0)" } ?? "Timecode · output not set")
                }
            }
            .font(.manrope(12))
            .foregroundStyle(Brand.steel)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.25)))
            .help("Audio output arrives in the next build.")
        }
        .padding(.top, 52)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(cornerRadius: 18, alpha: 0.64)
    }

    private func channels(_ c: [Int]) -> String {
        c.count == 2 ? "\(c[0])–\(c[1])" : c.map(String.init).joined(separator: ", ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.manrope(11, .bold)).tracking(1.1).foregroundStyle(Brand.graphite)
                .padding(.horizontal, 10).padding(.bottom, 4)
            content()
        }
    }

    private func navRow(_ title: String, selected: Bool, badge: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.manrope(13.5, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Brand.gold : Brand.ink)
                Spacer()
                if let badge {
                    Text("\(badge)").font(.manrope(11, .bold)).foregroundStyle(Color(hex: 0x1A1306))
                        .padding(.horizontal, 7).background(Capsule().fill(Brand.warn))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Brand.phantom : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Player bar

struct TransportButtons: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport

    var body: some View {
        HStack(spacing: 2) {
            Button { model.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 15)) }
                .help("Previous song (←)")
            Button { transport.toggle() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 26)
            }
            .help("Play or pause (Space)")
            Button { model.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 15)) }
                .help("Next song (→)")
        }
        .buttonStyle(IconButtonStyle())
    }
}

struct PlayerBar: View {
    @EnvironmentObject private var model: AppModel
    let morph: Namespace.ID

    var body: some View {
        HStack(spacing: 14) {
            TransportButtons()
            if let song = model.currentSong {
                HStack(spacing: 12) {
                    SongArt(song: song, cornerRadius: 6)
                        .frame(width: 38, height: 38)
                        .matchedGeometryEffect(id: "art", in: morph)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.manrope(13, .semibold)).foregroundStyle(Brand.ink)
                            .matchedGeometryEffect(id: "title", in: morph)
                        SongProgress { position, length in
                            VStack(spacing: 3) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.14))
                                        Capsule().fill(Brand.ink).frame(width: length > 0 ? geo.size.width * position / length : 0)
                                    }
                                }
                                .frame(height: 3)
                                HStack {
                                    Text(TimeFormat.clock(position))
                                    Spacer()
                                    Text("−" + TimeFormat.clock(max(0, length - position)))
                                }
                                .font(.manrope(11.5).monospacedDigit())
                                .foregroundStyle(Brand.space)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 46)
                .contentShape(Rectangle())
                .onTapGesture { model.go(.timeline) }
                .help("Open the song timeline (Return)")
            } else {
                Spacer()
            }
            Button { model.go(.timeline) } label: {
                Label("Timeline", systemImage: "arrow.up.left.and.arrow.down.right").font(.manrope(11.5, .semibold))
            }
            .buttonStyle(QuietButtonStyle())
            Button { model.go(.clock) } label: { Image(systemName: "clock").font(.system(size: 14)) }
                .buttonStyle(IconButtonStyle())
                .help("Full-screen clock (⇧⌘F)")
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .glass(cornerRadius: 16, alpha: 0.76)
        .matchedGeometryEffect(id: "bar", in: morph)
    }
}

// MARK: Clock hero

struct ClockHero: View {
    @EnvironmentObject private var model: AppModel
    let morph: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StateChips()
                Spacer()
                HStack(spacing: 2) {
                    modeButton("Show TC", on: model.showsShowTimecode) { model.showsShowTimecode = true }
                    modeButton("Song time", on: !model.showsShowTimecode) { model.showsShowTimecode = false }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
            }
            GeometryReader { geo in
                LiveClock(size: min(150, geo.size.width / 6.2), weight: .light, songTime: !model.showsShowTimecode)
                    .matchedGeometryEffect(id: "clock", in: morph)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            HStack(alignment: .firstTextBaseline) {
                if let song = model.currentSong {
                    Text(song.title).font(.manrope(20, .semibold)).foregroundStyle(Brand.ink)
                    Text(positionLine(song)).font(.manrope(14, .medium)).foregroundStyle(Brand.space)
                }
                Spacer()
                if let next = model.nextSong {
                    HStack(spacing: 10) {
                        Text("Up next").foregroundStyle(Brand.space)
                        SongArt(song: next).frame(width: 30, height: 30)
                        Text(next.title).font(.manrope(13, .semibold)).foregroundStyle(Brand.ink)
                        SongProgress { position, length in
                            Text("· starts in \(TimeFormat.clock(max(0, length - position)))").monospacedDigit()
                        }
                        .foregroundStyle(Brand.steel)
                    }
                    .font(.manrope(13))
                }
            }
        }
    }

    private func positionLine(_ song: Song) -> String {
        let q = model.queue
        let index = (q.firstIndex { $0.id == song.id } ?? 0) + 1
        return "Song \(index) of \(q.count) · \(model.setlist?.name ?? "")"
    }

    private func modeButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.manrope(12, .semibold)).foregroundStyle(on ? Brand.ink : Brand.space)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Brand.phantom : .clear))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Song list

struct SongList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            row {
                Text("#").frame(width: 44)
                Text("SONG").frame(maxWidth: .infinity, alignment: .leading)
                Text("TIMECODE START").frame(width: 150, alignment: .leading)
                Text("LENGTH").frame(width: 84, alignment: .leading)
                Text("RATE").frame(width: 80, alignment: .leading)
                Text("STATUS").frame(width: 180, alignment: .leading)
            }
            .font(.manrope(11, .bold)).tracking(1.1).foregroundStyle(Brand.graphite)
            .frame(height: 38)
            Divider().overlay(.white.opacity(0.06))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, song in
                        songRow(song, index: index + 1)
                        Divider().overlay(.white.opacity(0.04))
                    }
                }
            }
        }
        .solidPanel()
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }.padding(.horizontal, 18)
    }

    private func songRow(_ song: Song, index: Int) -> some View {
        let isCurrent = model.currentSong?.id == song.id
        let issues = model.issues(for: song)
        return row {
            Group {
                if isCurrent {
                    PlayingIndicator(isPlaying: transport.isPlaying)
                } else {
                    Text("\(song.number ?? index)").foregroundStyle(Brand.graphite)
                }
            }
            .font(.manrope(13, .semibold))
            .frame(width: 44)

            HStack(spacing: 12) {
                SongArt(song: song).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(song.title).font(.manrope(13.5, .semibold)).foregroundStyle(isCurrent ? Brand.gold : Brand.ink).lineLimit(1)
                        if !song.markers.isEmpty {
                            Capsule().fill(Brand.gold).frame(width: 3, height: 12).help("Has markers")
                        }
                    }
                    Text(fileName(song.masterPath)).font(.manrope(11.5)).foregroundStyle(Brand.graphite).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(song.start.description).frame(width: 150, alignment: .leading)
            Text(song.length.map(TimeFormat.clock) ?? "—").frame(width: 84, alignment: .leading)
            Text(song.rate.shortName).frame(width: 80, alignment: .leading)
            HStack(spacing: 8) {
                StatusDot(color: statusColor(issues))
                Text(statusText(issues)).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
        }
        .font(.manrope(13).monospacedDigit())
        .foregroundStyle(Brand.steel)
        .frame(height: 52)
        .background(isCurrent ? Brand.gold.opacity(0.09) : (selected == song.id ? Color.white.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !isCurrent { model.cue(song) }
            model.go(.timeline)
        }
        .onTapGesture { selected = song.id }
        .contextMenu {
            Button("Cue This Song") { model.cue(song) }
            Button("Open Timeline") { model.cue(song); model.go(.timeline) }
        }
    }

    private func fileName(_ path: String?) -> String {
        guard let path else { return "No master matched" }
        return (path as NSString).lastPathComponent
    }

    private func statusColor(_ issues: [ShowIssue]) -> Color {
        if issues.contains(where: { $0.severity == .error }) { return Color(hex: 0xE5675A) }
        return issues.isEmpty ? Brand.ok : Brand.warn
    }

    private func statusText(_ issues: [ShowIssue]) -> String {
        guard let first = issues.max(by: { $0.severity < $1.severity }) else { return "Ready" }
        switch first.kind {
        case .missingMaster: return "No master"
        case .missingTimecode: return "No timecode file"
        case .unreadableFile: return "Can't read a file"
        case .noTimecodeFound: return "No timecode found"
        case .startMismatch: return "Check timecode"
        case .rateMismatch: return "Frame rate differs"
        case .timecodeJump, .timecodeDropout: return "Timecode glitch"
        case .lengthMismatch: return "Lengths differ"
        case .sampleRateMismatch: return "Sample rates differ"
        case .deviceSampleRate: return "Ready (converted)"
        case .overlap: return "Overlaps previous"
        case .duplicateStart: return "Same start as another"
        }
    }
}
