import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
    @EnvironmentObject private var model: AppModel
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
                    .dropDestination(for: URL.self) { urls, _ in
                        guard !model.locked else { return false }
                        model.addAudio(urls)
                        return true
                    }
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
                    if let artist = model.show?.artist {
                        Text(artist.uppercased()).font(.manrope(10.5, .bold)).tracking(0.8).foregroundStyle(Brand.gold).lineLimit(1)
                    }
                    Text(model.show?.name ?? "No show").font(.manrope(13, .bold)).foregroundStyle(Brand.ink).lineLimit(2)
                    Text("\(model.show?.songs.count ?? 0) songs · \(model.show?.defaultRate.displayName ?? "")")
                        .font(.manrope(11.5)).foregroundStyle(Brand.space)
                    Button { model.revealShowFile() } label: {
                        Text("Saved automatically").font(.manrope(11)).foregroundStyle(Brand.graphite)
                    }
                    .buttonStyle(.plain)
                    .help("Every change saves itself to Documents › Vivid Playback. Click to show the file in Finder. ⌘S saves once more; ⇧⌘S saves a copy.")
                }
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .contextMenu { Button("Show Info…") { model.showInfoShown = true }.disabled(model.locked) }
            .onTapGesture(count: 2) { if !model.locked { model.showInfoShown = true } }

            section("Library") {
                navRow("Albums", selected: model.screen == .albums) { model.go(.albums) }
                navRow("Now playing", selected: model.screen == .library) { model.go(.library) }
            }

            section("Setlists") {
                ForEach(model.show?.setlists ?? []) { list in
                    navRow(list.name, selected: model.setlist?.id == list.id) {
                        model.select(setlist: list)
                    }
                    .contextMenu {
                        Button("Edit Setlist…") { model.select(setlist: list); model.setlistEditorShown = true }
                        Button("Duplicate") { model.duplicateSetlist(list) }
                        Button("Delete") { model.deleteSetlist(list) }.disabled((model.show?.setlists.count ?? 0) < 2)
                    }
                    .disabled(model.locked && model.transport.isPlaying)
                }
                if !model.locked {
                    Button { model.setlistEditorShown = true } label: {
                        Label("Edit setlist", systemImage: "list.bullet").font(.manrope(12.5, .medium)).foregroundStyle(Brand.space)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                }
            }

            section("Check") {
                navRow("Issues", selected: false, badge: model.activeIssues.isEmpty ? nil : model.activeIssues.count) {
                    model.issuesShown = true
                }
            }

            Spacer()

            if model.locked {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(Brand.gold)
                    Text("Show mode").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.ink)
                    Spacer()
                    Button("Unlock") { model.locked = false }.buttonStyle(.plain).font(.manrope(12)).foregroundStyle(Brand.space)
                }
                .padding(.horizontal, 10)
            }
            OutputsBox()
        }
        .padding(.top, 52)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(cornerRadius: 18, alpha: 0.64)
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

struct OutputsBox: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport

    var body: some View {
        let routing = model.show?.routing ?? OutputRouting()
        let live = transport.audio.isRunning
        Button { model.outputShown = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(live ? (transport.deviceName ?? "Audio output") : "No audio output")
                    .font(.manrope(12, .semibold)).foregroundStyle(Brand.ink).lineLimit(1)
                HStack(spacing: 8) {
                    StatusDot(color: live ? Brand.ok : Brand.graphite)
                    Text("Master · \(channels(routing.masterChannels))")
                }
                HStack(spacing: 8) {
                    StatusDot(color: live && transport.timecodeRouted ? (transport.isPlaying ? Brand.ok : Brand.gold) : Brand.warn,
                              pulsing: live && transport.timecodeRouted && transport.isPlaying)
                    Text(routing.timecodeChannel.map { "Timecode · Out \($0)" } ?? "Timecode · not set")
                }
            }
            .font(.manrope(12))
            .foregroundStyle(Brand.steel)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.25)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Audio output (⌥⌘O)")
    }

    private func channels(_ c: [Int]) -> String {
        c.count == 2 ? "Out \(c[0])–\(c[1])" : c.first.map { "Out \($0) (mono)" } ?? "not set"
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
    @State private var dropTarget: UUID?
    @State private var issuesFor: UUID?

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
            .overlay(alignment: .trailing) { sortControls.padding(.trailing, 14) }
            Divider().overlay(.white.opacity(0.06))
            ScrollView {
                LazyVStack(spacing: 0) {
                    let songs = model.visibleSongs
                    let order = model.setlistSongs.map(\.id)
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        // Acts as sections, like discs on an album (in setlist order only).
                        if model.sort == .setlist, let part = song.part, index == 0 || songs[index - 1].part != part {
                            sectionHeader(part)
                        }
                        songRow(song, index: (order.firstIndex(of: song.id) ?? index) + 1)
                        Divider().overlay(.white.opacity(0.04))
                    }
                }
            }
        }
        .solidPanel()
    }

    private var sortControls: some View {
        HStack(spacing: 10) {
            if model.sort != .setlist {
                Text("Playback still follows the setlist").font(.manrope(11)).foregroundStyle(Brand.space)
                Button("Save This Order") { model.saveSortedOrder() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.locked)
                    .help("Make this the setlist's order")
            }
            Menu {
                Picker("Sort by", selection: $model.sort) {
                    ForEach(SetlistSort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Hide Skipped Songs", isOn: $model.hideSkipped)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
                    Text(model.sort.displayName)
                }
                .font(.manrope(11.5, .semibold))
                .foregroundStyle(model.sort == .setlist ? Brand.space : Brand.gold)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort the list. Drag songs to reorder the setlist (in setlist order).")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased()).font(.manrope(11, .bold)).tracking(1.2).foregroundStyle(Brand.gold)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(Color.white.opacity(0.015))
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }.padding(.horizontal, 18)
    }

    private func songRow(_ song: Song, index: Int) -> some View {
        let isCurrent = model.currentSong?.id == song.id
        let issues = model.issues(for: song)
        let skipped = model.isSkipped(song)
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

            Text(song.hasTimecode ? song.start.description : "—").frame(width: 150, alignment: .leading)
            Text(song.length.map(TimeFormat.clock) ?? "—").frame(width: 84, alignment: .leading)
            Text(song.hasTimecode ? song.rate.shortName : "—").frame(width: 80, alignment: .leading)
            Button { if !issues.isEmpty || !model.hiddenIssues(for: song).isEmpty { issuesFor = song.id } } label: {
                HStack(spacing: 8) {
                    StatusDot(color: skipped ? Brand.graphite : statusColor(issues))
                    Text(skipped ? "Skipped tonight" : (issues.isEmpty && !song.hasTimecode ? "Ready · no timecode" : statusText(issues))).lineLimit(1)
                    if issues.count > 1 && !skipped {
                        Text("+\(issues.count - 1)").font(.manrope(11, .bold)).foregroundStyle(Brand.space)
                    }
                    if !issues.isEmpty && !skipped {
                        Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Brand.space)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 180, alignment: .leading)
            .help(issues.isEmpty ? "" : "Click to see what's wrong with \(song.title)")
            .popover(isPresented: Binding(get: { issuesFor == song.id }, set: { if !$0 { issuesFor = nil } }), arrowEdge: .leading) {
                SongIssuesPopover(song: song).environmentObject(model)
            }
        }
        .opacity(skipped ? 0.45 : 1)
        .font(.manrope(13).monospacedDigit())
        .foregroundStyle(Brand.steel)
        .frame(height: 52)
        .background(isCurrent ? Brand.gold.opacity(0.09) : (selected == song.id ? Color.white.opacity(0.04) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.champagne.opacity(dropTarget == song.id ? 0.7 : 0), lineWidth: 1.5))
        .onDrag {
            // Drag a song to reorder the setlist.
            NSItemProvider(object: "vivid-song:\(song.id.uuidString)" as NSString)
        }
        .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: Binding(
            get: { dropTarget == song.id },
            set: { on in dropTarget = on ? song.id : (dropTarget == song.id ? nil : dropTarget) })) { providers in
            guard !model.locked, let provider = providers.first else { return false }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // An audio file dropped on a song: the app listens to tell timecode from a master.
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, FileMatcher.isAudio(url) else { return }
                    DispatchQueue.main.async { model.dropFile(url, on: song) }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, text.hasPrefix("vivid-song:"),
                          let id = UUID(uuidString: String(text.dropFirst("vivid-song:".count))), id != song.id else { return }
                    DispatchQueue.main.async { model.moveSongs([id], before: song.id) }
                }
                return true
            }
            return false
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !skipped else { return }
            if !isCurrent { model.cue(song) }
            model.go(.timeline)
        }
        .onTapGesture { selected = song.id }
        .contextMenu {
            Button("Cue This Song") { model.cue(song) }.disabled(skipped)
            Button("Open Timeline") { model.cue(song); model.go(.timeline) }.disabled(skipped)
            Divider()
            Group {
                Button("Move Up") { model.moveUp(song) }
                Button("Move Down") { model.moveDown(song) }
                Button("Move to Top") { model.moveToTop(song) }
                Button("Move to Bottom") { model.moveToBottom(song) }
            }
            .disabled(model.locked || model.sort != .setlist)
            Divider()
            Button("Choose Master File…") { model.choose(.master, for: song) }.disabled(model.locked)
            Button("Choose Timecode File…") { model.choose(.timecode, for: song) }.disabled(model.locked)
            if song.masterPath != nil { Button("Remove Master File") { model.removeFile(.master, from: song) }.disabled(model.locked) }
            if song.timecodePath != nil { Button("Remove Timecode File") { model.removeFile(.timecode, from: song) }.disabled(model.locked) }
            Divider()
            Button(skipped ? "Play Tonight" : "Skip Tonight") { model.toggleSkip(song) }.disabled(model.locked)
            Button("Remove from Setlist") { model.removeFromSetlist(song) }.disabled(model.locked)
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
        case .missingTimecode: return "Generated timecode"
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
