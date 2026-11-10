import SwiftUI
import PlaybackCore

/// One screen: drop the show folder. Everything else is found and checked for you.
struct FirstRunView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ImportFlow(mode: .newShow)
            .padding(.horizontal, 44)
            .padding(.top, 40)
            .padding(.bottom, 36)
            .frame(width: 640)
            .glass(cornerRadius: 24, alpha: 0.64)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Anywhere in the window takes a drop, not just the card.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                if case .running = model.importState { return false }
                model.importFolder(url)
                return true
            }
    }
}

/// Add Album: the same import, in a sheet over the Albums page. A show imported here is added
/// to Albums without interrupting what's playing; open it now if nothing is.
struct AddAlbumSheet: View {
    var body: some View {
        ImportFlow(mode: .addAlbum)
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 28)
            .frame(width: 620)
            .background(Brand.phantom)
            .preferredColorScheme(.dark)
    }
}

/// Drop a folder, choose one, open a show file or try the example; then see what was found.
struct ImportFlow: View {
    enum Mode { case newShow, addAlbum }
    let mode: Mode
    @EnvironmentObject private var model: AppModel
    @State private var targeted = false
    /// Who and what the imported show is called (editable before it's saved).
    @State private var artist = ""
    @State private var showName = ""

    var body: some View {
        VStack(spacing: 18) {
            if mode == .newShow { Emblem(width: 54) }
            Group {
                switch model.importState {
                case .idle, .failed:
                    dropPrompt
                case .running(let step):
                    progress(step)
                case .finished(let report):
                    results(report)
                }
            }
            .transition(.opacity)
        }
        .animation(.vivid(0.35), value: stateKey)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !isRunning else { return false }
            importDropped(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var stateKey: Int {
        switch model.importState {
        case .idle: return 0
        case .failed: return 1
        case .running: return 2
        case .finished: return 3
        }
    }

    private var isRunning: Bool {
        if case .running = model.importState { return true }
        return false
    }

    /// A show file dropped on Add Album is added as it is; anything else is imported.
    private func importDropped(_ url: URL) {
        if mode == .addAlbum && url.pathExtension == ShowStore.fileExtension {
            model.addShowFile(url)
        } else {
            model.importFolder(url)
        }
    }

    private var dropPrompt: some View {
        VStack(spacing: 18) {
            Text(mode == .addAlbum ? "Add an album" : "Drop your show folder here")
                .font(.manrope(mode == .addAlbum ? 26 : 32, .semibold))
                .foregroundStyle(Brand.ink)
            Text(mode == .addAlbum
                 ? "Drop a show folder: the offset sheet, the masters and the timecode files. Each setlist in it becomes an album."
                 : "Put the offset sheet, the masters and the timecode files in one folder. Vivid Playback matches them up and checks every song.")
                .font(.manrope(14.5))
                .foregroundStyle(Brand.steel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            VStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(Brand.champagne)
                Text("Folder, sheet or audio files").font(.manrope(13)).foregroundStyle(Brand.space)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Brand.champagne.opacity(targeted ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(targeted ? 0.05 : 0)))
            )
            .animation(.vivid(0.2), value: targeted)
            if case .failed(let message) = model.importState {
                Text(message)
                    .font(.manrope(13))
                    .foregroundStyle(Brand.warn)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 10) {
                if cancelTitle != nil {
                    Button(cancelTitle ?? "") { cancel() }
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 0)
                }
                Button("Choose folder…") { model.chooseFolder() }
                    .buttonStyle(QuietButtonStyle(prominent: mode == .addAlbum))
                Button("Open show file…") {
                    if mode == .addAlbum { model.chooseShowFileForAlbums() } else { model.openShowPanel() }
                }
                    .buttonStyle(QuietButtonStyle())
                    .help("A .vividshow saved on this Mac, a USB stick or another drive")
                Button("Try the example show") { model.tryExampleShow() }
                    .buttonStyle(QuietButtonStyle(prominent: mode == .newShow))
            }
        }
    }

    /// Add Album always has Cancel; the import screen has it when a show is already open.
    private var cancelTitle: String? {
        switch mode {
        case .addAlbum: return "Cancel"
        case .newShow: return model.show != nil ? "Cancel" : nil
        }
    }

    private func cancel() {
        switch mode {
        case .addAlbum:
            model.importState = .idle
            model.addAlbumShown = false
        case .newShow:
            model.cancelImport()
        }
    }

    private func progress(_ step: ImportStep) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            Text(stepText(step)).font(.manrope(14)).foregroundStyle(Brand.steel)
        }
        .frame(height: 220)
    }

    private func stepText(_ step: ImportStep) -> String {
        switch step {
        case .scanning: return "Looking through the folder…"
        case .readingSheet(let name): return "Reading \(name)…"
        case .matching: return "Matching masters and timecode files…"
        case .checking(let song, let i, let n): return "Checking \(song) (\(i) of \(n))…"
        case .done: return "Done."
        }
    }

    private func results(_ report: ImportReport) -> some View {
        let n = report.show.songs.count
        let findings = report.issues.sorted { $0.severity > $1.severity }
        return VStack(spacing: 14) {
            Text(report.show.name).font(.manrope(32, .semibold)).foregroundStyle(Brand.ink)
            ScrollView {
                VStack(spacing: 8) {
                    checkRow(ok: report.sheetProblems.isEmpty, title: "Offset sheet",
                             detail: "\(report.sheetURL?.lastPathComponent ?? "") · \(n) songs, \(report.show.defaultRate.displayName)")
                    ForEach(report.sheetProblems, id: \.self) { checkRow(ok: false, title: "In the sheet", detail: $0) }
                    checkRow(ok: report.masterCount == n, title: "Masters", detail: "\(report.masterCount) of \(n) matched")
                    checkRow(ok: report.timecodeCount == n, title: "Timecode", detail: "\(report.timecodeCount) of \(n) matched and read")
                    ForEach(report.ambiguities, id: \.self) { checkRow(ok: false, title: "Pick a file", detail: $0) }
                    ForEach(grouped(findings), id: \.title) { checkRow(ok: false, title: $0.title, detail: $0.detail) }
                    if !report.unmatchedFiles.isEmpty {
                        checkRow(ok: true, neutral: true, title: "Not used",
                                 detail: report.unmatchedFiles.prefix(6).joined(separator: ", ") + (report.unmatchedFiles.count > 6 ? "…" : ""))
                    }
                }
            }
            .frame(maxHeight: 360)
            Text(summary(report)).font(.manrope(14)).foregroundStyle(Brand.steel)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Artist").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel)
                    ArtistField(text: $artist, artists: model.knownArtists)
                }
                GridRow {
                    Text("Show").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel)
                    TextField("Show name", text: $showName).textFieldStyle(.roundedBorder).font(.manrope(14))
                }
            }
            .frame(maxWidth: 420)
            .onAppear {
                artist = report.show.artist ?? ""
                showName = report.show.name
            }
            HStack(spacing: 10) {
                Button("Start over") { model.importState = .idle }
                    .buttonStyle(QuietButtonStyle())
                if mode == .addAlbum {
                    Spacer(minLength: 0)
                    Button("Add and open") { model.openImported(report, artist: artist, name: showName) }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(model.transport.isPlaying)
                        .help(model.transport.isPlaying ? "Stop playback to open it now. Add it, and open it from Albums later." : "Add it to Albums and open it")
                    Button("Add to Albums") { model.saveImported(report, artist: artist, name: showName) }
                        .buttonStyle(QuietButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open show") { model.openImported(report, artist: artist, name: showName) }
                        .buttonStyle(QuietButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// One row per finding, except when several songs share the same one: then one row for them all.
    private func grouped(_ issues: [ShowIssue]) -> [(title: String, detail: String)] {
        var rows: [(title: String, detail: String)] = []
        var seen = Set<ShowIssue.Kind>()
        for issue in issues {
            let same = issues.filter { $0.kind == issue.kind }
            if same.count < 3 {
                rows.append((issue.title, issue.message))
            } else if !seen.contains(issue.kind) {
                seen.insert(issue.kind)
                let names = same.compactMap { i in report?.show.songs.first { $0.id == i.songID }?.title }
                let list = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " and \(names.count - 5) more" : "")
                rows.append(("\(same.count) songs \(phrase(issue.kind))", list))
            }
        }
        return rows
    }

    private var report: ImportReport? {
        if case .finished(let r) = model.importState { return r }
        return nil
    }

    private func phrase(_ kind: ShowIssue.Kind) -> String {
        switch kind {
        case .missingMaster: return "have no master matched"
        case .missingTimecode: return "use timecode generated from the sheet"
        case .duplicateStart: return "share a start timecode with another song"
        case .overlap: return "run into the next song's timecode"
        case .startMismatch: return "have timecode that doesn't match the sheet"
        case .rateMismatch: return "have a different frame rate from the sheet"
        default: return "need a look"
        }
    }

    private func summary(_ report: ImportReport) -> String {
        let n = report.show.songs.count
        if report.masterCount == 0 {
            return "\(n) songs read, timecode only for now. Add the masters and timecode files after opening: drop them (or their folder) on the song list."
        }
        let ready = report.readyCount
        if ready == n { return n == 1 ? "1 song ready." : "All \(n) songs ready." }
        let review = n - ready
        return "\(ready) \(ready == 1 ? "song" : "songs") ready. \(review) to review."
    }

    private func checkRow(ok: Bool, neutral: Bool = false, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill((neutral ? Brand.graphite : ok ? Brand.ok : Brand.warn).opacity(0.18))
                Text(neutral ? "–" : ok ? "✓" : "!").font(.manrope(12, .heavy))
                    .foregroundStyle(neutral ? Brand.steel : ok ? Brand.ok : Brand.warn)
            }
            .frame(width: 20, height: 20)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.manrope(14, .semibold)).foregroundStyle(Brand.ink)
                Text(detail).font(.manrope(12.5)).foregroundStyle(Brand.space).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.28)))
    }
}
