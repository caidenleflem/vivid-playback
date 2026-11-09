import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import QuartzCore
import PlaybackCore

/// Reads any audio format macOS can open, for checking and waveforms.
struct AVAudioFileReader: AudioFileReading {
    func info(of url: URL) throws -> AudioFileInfo {
        let file = try AVAudioFile(forReading: url)
        return AudioFileInfo(sampleRate: file.fileFormat.sampleRate, channelCount: Int(file.fileFormat.channelCount), frameCount: Int(file.length))
    }

    func readChannels(of url: URL) throws -> (sampleRate: Double, channels: [[Float]]) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw AudioFileError.unreadable(url.lastPathComponent) }
        let n = Int(buffer.frameLength)
        let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        return (format.sampleRate, channels)
    }
}

enum Waveform {
    /// Peak level per bucket across all channels, 0...1.
    static func peaks(of url: URL, buckets: Int = 1400) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let format = file.processingFormat
        let total = Int(file.length)
        let perBucket = max(1, total / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }
        var position = 0
        while position < total {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            if let data = buffer.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    let ch = data[c]
                    for i in 0..<n {
                        let b = min(buckets - 1, (position + i) / perBucket)
                        let v = abs(ch[i])
                        if v > peaks[b] { peaks[b] = v }
                    }
                }
            }
            position += n
        }
        let top = max(0.0001, peaks.max() ?? 1)
        return peaks.map { min(1, $0 / top) }
    }
}

enum ImportState {
    case idle
    case running(ImportStep)
    case finished(ImportReport)
    case failed(String)
}

enum Screen: Equatable {
    case firstRun, library, timeline, clock
}

struct MarkerEdit: Identifiable {
    let marker: Marker
    let song: Song
    var id: UUID { marker.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: Screen = .firstRun
    @Published var show: Show?
    @Published var packageURL: URL?
    @Published var issues: [ShowIssue] = []
    @Published var currentSongID: UUID?
    @Published var showsShowTimecode = true
    @Published var importState: ImportState = .idle
    @Published var waveforms: [UUID: [Float]] = [:]
    @Published var issuesShown = false
    @Published var outputShown = false
    @Published var setlistEditorShown = false
    @Published var goToShown = false
    @Published var markerEdit: MarkerEdit?
    @Published var selectedSetlistID: UUID?
    /// Show mode: playback only, nothing can be edited.
    @Published var locked = false
    @Published var stopAfterEach = UserDefaults.standard.bool(forKey: "stopAfterEach") {
        didSet { UserDefaults.standard.set(stopAfterEach, forKey: "stopAfterEach") }
    }
    @Published var devices: [AudioDevice] = []
    /// A short message after adding or changing files; clears itself.
    @Published var notice: String?

    let transport = Transport()
    private let reader = AVAudioFileReader()

    init() {
        transport.onSongEnd = { [weak self] in self?.advanceAfterSongEnd() }
        refreshDevices()
        AudioDevices.observeChanges { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDevices()
                self.transport.devicesChanged(routing: self.show?.routing ?? OutputRouting())
            }
        }
        // `--demo library|timeline|clock` opens the example show on that screen, rolling.
        // Used by the build to screenshot each screen.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--demo") {
            if i + 1 < args.count { runDemo(args[i + 1]) }
            return
        }
        reopenLastShow()
    }

    func refreshDevices() { devices = AudioDevices.all() }

    /// While a sheet is open, single-key shortcuts (Space, M, L, arrows) stay out of the way of typing.
    var sheetOpen: Bool { issuesShown || outputShown || setlistEditorShown || goToShown || markerEdit != nil }

    /// Every song in the setlist, in order, including the ones skipped tonight.
    var setlistSongs: [Song] {
        guard let show else { return [] }
        guard let setlist else { return show.songs }
        return setlist.songIDs.compactMap(show.song(id:))
    }

    func isSkipped(_ song: Song) -> Bool { setlist?.skipped.contains(song.id) ?? false }

    // MARK: Songs

    var setlist: Setlist? {
        guard let show else { return nil }
        return show.setlists.first { $0.id == selectedSetlistID } ?? show.setlists.first
    }

    /// The songs in play order, skipping the ones marked for tonight.
    var queue: [Song] {
        guard let show else { return [] }
        guard let setlist else { return show.songs }
        return setlist.songIDs.filter { !setlist.skipped.contains($0) }.compactMap(show.song(id:))
    }

    var currentSong: Song? {
        guard let id = currentSongID else { return queue.first }
        return show?.song(id: id)
    }

    var nextSong: Song? {
        let q = queue
        guard let cur = currentSong, let i = q.firstIndex(where: { $0.id == cur.id }), i + 1 < q.count else { return nil }
        return q[i + 1]
    }

    func issues(for song: Song) -> [ShowIssue] { issues.filter { $0.songID == song.id } }

    func cue(_ song: Song, play: Bool? = nil) {
        guard let show else { return }
        currentSongID = song.id
        transport.load(song, in: show, play: play)
        transport.preload(nextSong, in: show)
        loadWaveform(for: song)
    }

    func next() {
        guard let n = nextSong else { return }
        cue(n)
    }

    func previous() {
        let q = queue
        guard let cur = currentSong, let i = q.firstIndex(where: { $0.id == cur.id }) else { return }
        // Like a music player: back to the top first, then the song before.
        if transport.position() > 3 || i == 0 { transport.locate(transport.lowerBound) } else { cue(q[i - 1]) }
    }

    private func advanceAfterSongEnd() {
        if let n = nextSong {
            cue(n, play: !stopAfterEach)
        } else {
            transport.pause()
        }
    }

    /// The timecode at the playhead.
    func timecode(for song: Song, at position: Double) -> Timecode {
        song.start.adding(frames: Int((position * song.rate.framesPerSecond + 1e-6).rounded(.down)))
    }

    // MARK: Screens

    func go(_ target: Screen) {
        guard show != nil || target == .firstRun else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .vivid(0.55)) { screen = target }
    }

    func toggleTimeline() { go(screen == .timeline ? .library : .timeline) }
    func toggleClock() { go(screen == .clock ? .library : .clock) }

    // MARK: Editing (blocked in show mode)

    private func edit(_ change: (inout Show) -> Void) {
        guard !locked, var show else { return }
        change(&show)
        self.show = show
        if let song = currentSong { transport.update(song, in: show) }
        save()
    }

    func addMarker() {
        guard screen == .timeline, let song = currentSong else { return }
        let tc = timecode(for: song, at: transport.position())
        withAnimation(.vivid(0.45)) {
            edit { show in
                guard let i = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
                show.songs[i].markers.append(Marker(time: tc, label: "Marker \(show.songs[i].markers.count + 1)"))
                show.songs[i].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
            }
        }
    }

    func renameMarker(_ marker: Marker, in song: Song, to label: String) {
        let text = label.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        edit { show in
            guard let s = show.songs.firstIndex(where: { $0.id == song.id }),
                  let m = show.songs[s].markers.firstIndex(where: { $0.id == marker.id }) else { return }
            show.songs[s].markers[m].label = text
        }
    }

    func deleteMarker(_ marker: Marker, in song: Song) {
        withAnimation(.vivid(0.4)) {
            edit { show in
                guard let s = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
                show.songs[s].markers.removeAll { $0.id == marker.id }
            }
        }
    }

    func seconds(of marker: Marker, in song: Song) -> Double {
        Double(marker.time.frames(since: song.start)) / song.rate.framesPerSecond
    }

    /// Loops the stretch between the markers either side of the playhead (the whole song if
    /// there are none). Calling it again stops looping.
    func toggleLoop() {
        guard let song = currentSong else { return }
        if transport.loop != nil { transport.setLoop(nil); return }
        let p = transport.position()
        let points = song.markers.map { seconds(of: $0, in: song) }.sorted()
        let start = points.last(where: { $0 <= p }) ?? 0
        let end = points.first(where: { $0 > p }) ?? (song.length ?? transport.length)
        guard end - start > 0.25 else { return }
        transport.setLoop(start...end)
    }

    func updateSetlist(_ setlist: Setlist) {
        edit { show in
            guard let i = show.setlists.firstIndex(where: { $0.id == setlist.id }) else { return }
            show.setlists[i] = setlist
        }
    }

    func duplicateSetlist(_ setlist: Setlist) {
        let copy = Setlist(name: "\(setlist.name) copy", songIDs: setlist.songIDs, skipped: setlist.skipped)
        edit { $0.setlists.append(copy) }
        selectedSetlistID = copy.id
    }

    func newSetlist() {
        guard let show else { return }
        let list = Setlist(name: "New setlist", songIDs: show.songs.map(\.id))
        edit { $0.setlists.append(list) }
        selectedSetlistID = list.id
    }

    func deleteSetlist(_ setlist: Setlist) {
        guard let show, show.setlists.count > 1 else { return }
        edit { $0.setlists.removeAll { $0.id == setlist.id } }
        if selectedSetlistID == setlist.id { selectedSetlistID = self.show?.setlists.first?.id }
    }

    func toggleSkip(_ song: Song) {
        guard var list = setlist else { return }
        if list.skipped.contains(song.id) { list.skipped.remove(song.id) } else { list.skipped.insert(song.id) }
        updateSetlist(list)
    }

    func select(setlist: Setlist) {
        selectedSetlistID = setlist.id
        if let current = currentSong, !queue.contains(where: { $0.id == current.id }), let first = queue.first, !transport.isPlaying {
            cue(first)
        }
    }

    // MARK: Output

    func updateRouting(_ change: (inout OutputRouting) -> Void) {
        guard var show else { return }
        let before = show.routing
        change(&show.routing)
        self.show = show
        save()
        if before.deviceUID != show.routing.deviceUID {
            transport.configure(routing: show.routing)
        } else {
            transport.applyRouting(show.routing)
        }
    }

    /// True when the show still needs a timecode output chosen.
    var needsTimecodeOutput: Bool { show != nil && show?.routing.timecodeChannel == nil }

    // MARK: Go to timecode

    /// Finds the song that holds `text` (a timecode), cues it and moves the playhead there.
    /// Returns a message when it can't.
    func goTo(timecode text: String) -> String? {
        guard let show else { return "Open a show first." }
        let songs = queue.isEmpty ? show.songs : queue
        for song in songs where song.hasTimecode {
            guard let tc = Timecode(text, rate: song.rate) else { continue }
            let offset = Double(tc.frames(since: song.start)) / song.rate.framesPerSecond
            if offset >= -song.fileOffset && offset <= (song.length ?? 0) {
                if currentSong?.id != song.id { cue(song, play: false) }
                transport.locate(offset)
                return nil
            }
        }
        if Timecode(text, rate: show.defaultRate) == nil { return "That isn't a timecode. Use HH:MM:SS:FF." }
        return "No song in this setlist plays at \(text)."
    }

    // MARK: Adding audio after import

    /// Matches files (or whole folders) to the songs still missing a master or timecode file.
    func addAudio(_ urls: [URL]) {
        guard !locked, var show else { return }
        let result = ShowImporter.attach(ShowImporter.expand(urls), to: &show)
        self.show = show
        save()
        filesChanged()
        post(result.summary)
    }

    func chooseAudio() {
        guard !locked, show != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose masters, timecode files or a folder of them. They're matched to songs by number or title."
        if panel.runModal() == .OK { addAudio(panel.urls) }
    }

    /// Sets one song's master or timecode file from a file picker.
    func choose(_ role: AudioRole, for song: Song) {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Use This File"
        panel.message = role == .timecode ? "Choose the timecode (LTC) file for \(song.title)." : "Choose the master for \(song.title)."
        if panel.runModal() == .OK, let url = panel.url { assign(url, role: role, to: song) }
    }

    func assign(_ url: URL, role: AudioRole, to song: Song) {
        guard !locked, var show else { return }
        do {
            let updated = try ShowImporter.assign(url, role: role, songID: song.id, in: &show, reader: reader)
            self.show = show
            save()
            filesChanged()
            if role == .timecode, !song.hasTimecode, let u = updated {
                post("\(u.title) now sends timecode, starting at \(u.start) (read from \(url.lastPathComponent)).")
            } else {
                post("\(song.title): \(role == .timecode ? "timecode" : "master") is now \(url.lastPathComponent).")
            }
        } catch {
            post(String(describing: error))
        }
    }

    func removeFile(_ role: AudioRole, from song: Song) {
        guard !locked, var show else { return }
        ShowImporter.remove(role, songID: song.id, in: &show)
        self.show = show
        save()
        filesChanged()
    }

    /// After files change: drop cached audio and waveforms, reload the cued song if it isn't
    /// playing (never mid-song), and check everything again.
    private func filesChanged() {
        guard let show else { return }
        transport.invalidateCache()
        waveforms = [:]
        if let song = currentSong {
            if transport.isPlaying { transport.update(song, in: show) } else { cue(song, play: false) }
        }
        recheck()
    }

    func post(_ text: String) {
        withAnimation(.vivid(0.3)) { notice = text }
        Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if notice == text { withAnimation(.vivid(0.3)) { notice = nil } }
        }
    }

    // MARK: Import, open, save

    func chooseFolder() {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder with the offset sheet, the masters and the timecode files."
        if panel.runModal() == .OK, let url = panel.url { importFolder(url) }
    }

    func importFolder(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if url.pathExtension == ShowStore.fileExtension { open(package: url); return }
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        // A dropped sheet is the sheet. Its folder is searched for audio unless it's a catch-all
        // folder like Downloads, where other files would only cause wrong matches.
        let sheetExtensions: Set<String> = ["csv", "tsv", "txt", "xlsx"]
        let chosen = !isDir.boolValue && sheetExtensions.contains(url.pathExtension.lowercased()) ? url : nil
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let catchAll = [home] + [.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first?.standardizedFileURL }
        let scanAudio = !(chosen != nil && catchAll.contains(folder.standardizedFileURL))
        importState = .running(.scanning)
        let reader = self.reader
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try ShowImporter(reader: reader).importFolder(folder, sheet: chosen, scanAudio: scanAudio, progress: { step in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if case .running = self.importState { self.importState = .running(step) }
                        }
                    })
                }.value
                withAnimation(.vivid(0.4)) { importState = .finished(report) }
            } catch {
                importState = .failed(String(describing: error))
            }
        }
    }

    func tryExampleShow() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Vivid Playback Example Tour 2027")
        importState = .running(.scanning)
        Task {
            do {
                try await Task.detached { try ExampleShow.write(to: folder) }.value
                importFolder(folder)
            } catch {
                importState = .failed(String(describing: error))
            }
        }
    }

    /// Opens an imported show and saves it as a package in ~/Documents/Vivid Playback.
    func openImported(_ report: ImportReport) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Vivid Playback")
        let package = docs.appendingPathComponent("\(report.show.name).\(ShowStore.fileExtension)")
        var show = report.show
        // Start on this Mac's interface; Caiden picks the timecode output once.
        if show.routing.deviceUID == nil { show.routing.deviceUID = AudioDevices.defaultOutput()?.uid }
        load(show, package: package, issues: report.issues)
        save()
        importState = .idle
        go(.library)
        if needsTimecodeOutput { outputShown = true }
    }

    func open(package: URL) {
        do {
            let show = try ShowStore.load(from: package)
            load(show, package: package, issues: [])
            go(.library)
            recheck()
        } catch {
            importState = .failed("Couldn't open \(package.lastPathComponent): \(error.localizedDescription)")
            screen = .firstRun
        }
    }

    /// Re-reads every song's files in the background: they may have changed or moved.
    func recheck() {
        guard let show else { return }
        let reader = self.reader
        let rate = transport.audio.isRunning ? transport.audio.sampleRate : nil
        Task {
            let (checked, issues) = await Task.detached { () -> (Show, [ShowIssue]) in
                var copy = show
                let result = ShowImporter(reader: reader).check(&copy, deviceSampleRate: rate)
                for (i, song) in copy.songs.enumerated() where copy.songs[i].timecodeFileChannel == nil {
                    copy.songs[i].timecodeFileChannel = result.channels[song.id]
                }
                return (copy, result.issues)
            }.value
            self.issues = issues
            guard var current = self.show else { return }
            for (i, song) in current.songs.enumerated() {
                guard let fresh = checked.song(id: song.id) else { continue }
                if song.length == nil { current.songs[i].length = fresh.length }
                if song.timecodeFileChannel == nil { current.songs[i].timecodeFileChannel = fresh.timecodeFileChannel }
            }
            self.show = current
        }
    }

    func openShowPanel() {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Open Show"
        if panel.runModal() == .OK, let url = panel.url { open(package: url) }
    }

    /// Points the show at a folder its files moved to, then checks everything again.
    func relink() {
        guard !locked, show != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder the show's masters and timecode files are in now."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit { $0.mediaFolder = url.standardizedFileURL.path }
        transport.invalidateCache()
        waveforms = [:]
        if let song = currentSong { cue(song, play: false) }
        recheck()
    }

    private func load(_ show: Show, package: URL, issues: [ShowIssue]) {
        transport.pause()
        self.show = show
        self.packageURL = package
        self.issues = issues
        self.selectedSetlistID = show.setlists.first?.id
        waveforms = [:]
        transport.invalidateCache()
        transport.configure(routing: show.routing)
        if let first = queue.first { cue(first, play: false) }
        UserDefaults.standard.set(package.path, forKey: "lastShowPath")
    }

    func save() {
        guard let show, let packageURL else { return }
        try? ShowStore.save(show, to: packageURL)
    }

    private func reopenLastShow() {
        guard let path = UserDefaults.standard.string(forKey: "lastShowPath"),
              FileManager.default.fileExists(atPath: path) else { return }
        open(package: URL(fileURLWithPath: path))
        screen = .library
    }

    func newShow() {
        guard !locked else { return }
        transport.pause()
        importState = .idle
        go(.firstRun)
    }

    private func runDemo(_ name: String) {
        let target: Screen
        switch name {
        case "library": target = .library
        case "timeline": target = .timeline
        case "clock": target = .clock
        default: return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Vivid Playback Example Tour 2027")
        let reader = self.reader
        Task {
            guard let report = try? await Task.detached(operation: { () -> ImportReport in
                try ExampleShow.write(to: folder)
                return try ShowImporter(reader: reader).importFolder(folder, name: "Example Tour 2027")
            }).value else { return }
            var show = report.show
            show.routing.masterChannels = [1]
            show.routing.timecodeChannel = 2
            if target == .timeline, show.songs.count > 2 {
                let song = show.songs[2]
                show.songs[2].markers = [(0.4, "Hit 1"), (5, "Verse 1"), (11, "Chorus · big look"), (17, "Bridge · blackout")].map {
                    Marker(time: song.start.adding(frames: Int($0.0 * song.rate.framesPerSecond)), label: $0.1)
                }
            }
            load(show, package: folder.appendingPathComponent("Example.vividshow"), issues: report.issues)
            if let third = queue.dropFirst(2).first { cue(third, play: false) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            transport.locate(9.4)
            screen = target
            transport.play()
        }
    }

    // MARK: Waveforms

    func loadWaveform(for song: Song) {
        guard waveforms[song.id] == nil, let url = show?.url(forMediaPath: song.masterPath) else { return }
        Task {
            let peaks = await Task.detached(priority: .utility) { Waveform.peaks(of: url) }.value
            waveforms[song.id] = peaks
        }
    }
}
