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
    @State private var dropTarget: UUID?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 224)
                .padding(10)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text("Albums").font(.manrope(34, .bold)).foregroundStyle(Brand.ink).padding(.top, 70)
                    if entries.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "square.stack")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(Brand.champagne)
                            Text("Your shows live here").font(.manrope(22, .semibold)).foregroundStyle(Brand.ink)
                            Text("Every imported show appears as albums, one per setlist, grouped by artist.")
                                .font(.manrope(14)).foregroundStyle(Brand.steel).multilineTextAlignment(.center)
                            Button("Import a show…") { model.chooseFolder() }.buttonStyle(QuietButtonStyle(prominent: true))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                    }
                    ForEach(groups, id: \.artist) { group in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(group.artist).font(.manrope(20, .semibold)).foregroundStyle(Brand.ink)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 22, alignment: .top)],
                                      alignment: .leading, spacing: 26) {
                                ForEach(group.albums, id: \.setlist.id) { album in
                                    card(album.entry, album.setlist)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { model.refreshLibrary() }
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
            if byArtist[artist] == nil { order.append(artist) }
            for list in entry.show.setlists { byArtist[artist, default: []].append((entry, list)) }
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
        }
        .help("Click to open. Drop an image here to use it as the cover.")
    }
}

struct ShowInfoSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var artist = ""
    @State private var name = ""

    var body: some View {
        SheetFrame(title: "Show info", subtitle: "Shows are grouped by artist on the Albums page.", width: 460) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Artist").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel)
                TextField("Artist", text: $artist).textFieldStyle(.roundedBorder).font(.manrope(14))
                Text("Show").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel)
                TextField("Show name", text: $name).textFieldStyle(.roundedBorder).font(.manrope(14))
                HStack {
                    Spacer()
                    Button("Save") { model.updateShowInfo(artist: artist, name: name); dismiss() }
                        .buttonStyle(QuietButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            artist = model.show?.artist ?? ""
            name = model.show?.name ?? ""
        }
    }
}
