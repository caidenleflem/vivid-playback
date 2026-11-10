import SwiftUI
import AppKit
import PlaybackCore

/// A setlist's cover: the chosen image, or generated art in the song style.
struct AlbumCover: View {
    let setlist: Setlist
    let package: URL?
    var cornerRadius: CGFloat = 10

    var body: some View {
        if let path = setlist.artwork, let package, let image = NSImage(contentsOf: package.appendingPathComponent(path)) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        } else {
            ZStack(alignment: .bottomLeading) {
                SongArt(song: Song(title: setlist.name, start: Timecode(frameCount: 0, rate: .fps30)), cornerRadius: cornerRadius)
                Emblem(width: 34).opacity(0.85).padding(12)
            }
        }
    }
}

/// Every saved show, grouped by artist, one album per setlist.
struct AlbumsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    @State private var dropTarget: UUID?
    /// The album waiting for Delete to be confirmed.
    @State private var pendingDelete: (entry: ShowLibrary.Entry, setlist: Setlist)?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if entries.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "square.stack")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(Brand.champagne)
                            Text("Your shows live here").font(.manrope(22, .semibold)).foregroundStyle(Brand.ink)
                            Text("Every imported show appears as albums, one per setlist, grouped by artist.")
                                .font(.manrope(14)).foregroundStyle(Brand.steel).multilineTextAlignment(.center)
                            Button("Add an album…") { model.addAlbum() }.buttonStyle(QuietButtonStyle(prominent: true))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                    }
                    if !entries.isEmpty && groups.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(Brand.graphite)
                            Text("No albums match “\(query.trimmingCharacters(in: .whitespaces))”").font(.manrope(16, .semibold)).foregroundStyle(Brand.ink)
                            Text("Search looks at artists, shows and setlists.").font(.manrope(13)).foregroundStyle(Brand.space)
                            Button("Clear search") { query = "" }.buttonStyle(QuietButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 70)
                    }
                    ForEach(groups, id: \.artist) { group in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(group.artist).font(.manrope(20, .semibold)).foregroundStyle(Brand.ink)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 22, alignment: .top)],
                                      alignment: .leading, spacing: 26) {
                                ForEach(group.albums, id: \.setlist.id) { album in
                                    card(album.entry, album.setlist)
                                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                }
                                if group.artist == groups.last?.artist && query.isEmpty { addCard }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.vivid(0.35), value: albumIDs)
            }
        .onAppear { model.refreshLibrary() }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(deleteButton, role: .destructive) {
                if let p = pendingDelete { model.deleteAlbum(p.entry, setlistID: p.setlist.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Albums").font(.manrope(34, .bold)).foregroundStyle(Brand.ink)
            Spacer()
            if !entries.isEmpty { searchField }
            Button { model.addAlbum() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    Text("Add album")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.locked)
            .help("Import a show folder, open a show file, or try the example")
        }
        .padding(.top, 70)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.space)
            TextField("Search artists and albums", text: $query)
                .textFieldStyle(.plain)
                .font(.manrope(13))
                .foregroundStyle(Brand.ink)
                .focused($searchFocused)
                .onChange(of: searchFocused) { model.typingInField = $0 }
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Brand.graphite)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 250, height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(searchFocused ? 0.09 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.gold.opacity(searchFocused ? 0.5 : 0), lineWidth: 1))
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).allowsHitTesting(false))
        .onDisappear { if searchFocused { model.typingInField = false } }
        .help("Search (⌘F)")
    }

    /// The dashed "add" tile at the end of the grid.
    private var addCard: some View {
        Button { model.addAlbum() } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .foregroundStyle(.white.opacity(0.16))
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.02)))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(Brand.gold)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Brand.gold.opacity(0.12)))
                    }
                Text("Add album").font(.manrope(14, .semibold)).foregroundStyle(Brand.ink)
                Text("Import a show").font(.manrope(12)).foregroundStyle(Brand.space)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.locked)
    }

    private var albumIDs: [UUID] { groups.flatMap { $0.albums.map(\.setlist.id) } }

    private var deleteTitle: String {
        guard let p = pendingDelete else { return "" }
        return p.entry.show.setlists.count > 1 ? "Delete “\(p.setlist.name)”?" : "Delete “\(p.entry.show.name)”?"
    }

    private var deleteButton: String {
        guard let p = pendingDelete else { return "Delete" }
        return p.entry.show.setlists.count > 1 ? "Delete Album" : "Move Show to Trash"
    }

    private var deleteMessage: String {
        guard let p = pendingDelete else { return "" }
        if p.entry.show.setlists.count > 1 {
            return "The setlist goes; its songs, markers and triggers stay in \(p.entry.show.name). You can undo this."
        }
        return "It's the show's only album, so the show file goes to the Trash with its markers and triggers. Your audio files aren't touched. You can undo this."
    }

    /// Saved shows, plus the open one if it's kept somewhere else.
    private var entries: [ShowLibrary.Entry] {
        var list = model.library
        if let show = model.show, let url = model.packageURL,
           !list.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            list.insert(ShowLibrary.Entry(url: url, show: show), at: 0)
        }
        return list
    }

    private var groups: [(artist: String, albums: [(entry: ShowLibrary.Entry, setlist: Setlist)])] {
        var order: [String] = []
        var byArtist: [String: [(entry: ShowLibrary.Entry, setlist: Setlist)]] = [:]
        for entry in entries {
            let artist = entry.show.artist ?? "No artist"
            for list in entry.show.setlists
            where ShowLibrary.matches(query, artist: entry.show.artist, show: entry.show.name, setlist: list.name) {
                if byArtist[artist] == nil { order.append(artist) }
                byArtist[artist, default: []].append((entry, list))
            }
        }
        return order.map { ($0, byArtist[$0] ?? []) }
    }

    private func card(_ entry: ShowLibrary.Entry, _ list: Setlist) -> some View {
        let isOpen = entry.url.standardizedFileURL == model.packageURL?.standardizedFileURL && model.setlist?.id == list.id
        let count = list.songIDs.count - list.skipped.count
        return Button { model.openAlbum(entry, setlistID: list.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                AlbumCover(setlist: list, package: entry.url)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.champagne.opacity(dropTarget == list.id ? 0.8 : 0), lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 10)
                Text(list.name).font(.manrope(14, .semibold)).foregroundStyle(isOpen ? Brand.gold : Brand.ink).lineLimit(1)
                Text("\(entry.show.name) · \(count) songs · \(TimeFormat.clock(list.duration(in: entry.show)))")
                    .font(.manrope(12)).foregroundStyle(Brand.space).lineLimit(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.setArtwork(url, for: list.id, in: entry)
            return true
        } isTargeted: { on in dropTarget = on ? list.id : (dropTarget == list.id ? nil : dropTarget) }
        .contextMenu {
            Button("Open") { model.openAlbum(entry, setlistID: list.id) }
            Button("Choose Cover…") { model.chooseArtwork(for: list.id, in: entry) }.disabled(model.locked)
            if list.artwork != nil { Button("Remove Cover") { model.setArtwork(nil, for: list.id, in: entry) }.disabled(model.locked) }
            Button("Show Info…") { model.showInfoEntry = entry }.disabled(model.locked)
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button(entry.show.setlists.count > 1 ? "Delete Album…" : "Delete Show…", role: .destructive) {
                pendingDelete = (entry, list)
            }
            .disabled(model.locked || (isOpen && transport.isPlaying))
        }
        .help("Click to open. Drop an image here to use it as the cover.")
    }
}

/// An artist: type a new one, or pick one already in the library.
struct ArtistField: View {
    @Binding var text: String
    let artists: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField("Artist", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.manrope(14))
            if !artists.isEmpty {
                Menu {
                    ForEach(artists, id: \.self) { a in Button(a) { text = a } }
                    if !text.isEmpty {
                        Divider()
                        Button("No artist") { text = "" }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("An artist already in Albums")
            }
        }
    }
}

/// Artist and show name, for the open show or any saved one.
struct ShowInfoSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// nil: the open show.
    var entry: ShowLibrary.Entry? = nil
    @State private var artist = ""
    @State private var name = ""

    var body: some View {
        SheetFrame(title: "Show info", subtitle: "Albums are grouped by artist.", width: 460) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Artist").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel)
                ArtistField(text: $artist, artists: model.knownArtists)
                Text("Show").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel)
                TextField("Show name", text: $name).textFieldStyle(.roundedBorder).font(.manrope(14))
                HStack {
                    Spacer()
                    Button("Save") {
                        if let entry { model.updateShowInfo(entry, artist: artist, name: name) } else { model.updateShowInfo(artist: artist, name: name) }
                        dismiss()
                    }
                    .buttonStyle(QuietButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            let show = entry?.show ?? model.show
            artist = show?.artist ?? ""
            name = show?.name ?? ""
        }
    }
}
