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
        try readChannels(of: url, frames: nil)
    }

    func readChannels(of url: URL, seconds: Double) throws -> (sampleRate: Double, channels: [[Float]]) {
        let file = try AVAudioFile(forReading: url)
        return try readChannels(of: url, frames: AVAudioFrameCount(max(1, seconds * file.processingFormat.sampleRate)))
    }

    private func readChannels(of url: URL, frames limit: AVAudioFrameCount?) throws -> (sampleRate: Double, channels: [[Float]]) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let count = min(AVAudioFrameCount(file.length), limit ?? AVAudioFrameCount(file.length))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        try file.read(into: buffer, frameCount: count)
        guard let data = buffer.floatChannelData else { throw AudioFileError.unreadable(url.lastPathComponent) }
        let n = Int(buffer.frameLength)
        let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        return (format.sampleRate, channels)
    }
}

/// Peak levels through a master file, `perSecond` buckets for each second of the file.
struct WaveformData {
    var peaks: [Float] = []
    var perSecond: Double = 1
    /// Identifies this set of peaks, so the waveform is only redrawn when it changes.
    var token = UUID()

    /// The loudest peak between two times in the file (seconds), 0...1.
    func peak(from t0: Double, to t1: Double) -> Float {
        guard !peaks.isEmpty else { return 0 }
        let a = max(0, Int(t0 * perSecond)), b = min(peaks.count - 1, Int(t1 * perSecond))
        guard a < peaks.count, b >= 0 else { return 0 }
        if b <= a { return peaks[min(a, peaks.count - 1)] }
        var m: Float = 0
        for i in a...b where peaks[i] > m { m = peaks[i] }
        return m
    }
}

enum Waveform {
    /// Peak level per bucket across all channels, 0...1: 100 buckets a second (fine enough to
    /// zoom to a frame), at most 60 000.
    static func peaks(of url: URL) -> WaveformData {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return WaveformData() }
        let format = file.processingFormat
        let total = Int(file.length)
        let seconds = Double(total) / format.sampleRate
        let buckets = max(1, min(60_000, Int(seconds * 100)))
        let perBucket = max(1, total / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return WaveformData() }
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
        return WaveformData(peaks: peaks.map { min(1, $0 / top) }, perSecond: format.sampleRate / Double(perBucket))
    }
}

enum ImportState {
    case idle
    case running(ImportStep)
    case finished(ImportReport)
    case failed(String)
}

enum Screen: Equatable {
    case firstRun, library, timeline, clock, albums, connections, player

    /// The pages that share the sidebar: moving between them changes only the page.
    var hasSidebar: Bool { self == .library || self == .albums || self == .connections }
}

/// The song as it was before the last fix, so it can be put back.
struct FixUndo {
    let song: Song
    let label: String
}

struct MarkerEdit: Identifiable {
    let marker: Marker
    let song: Song
    /// Open on choosing this action (from the Trigger menu).
    var action: LaneAction? = nil
    var id: UUID { marker.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: Screen = .firstRun
    /// The screen before the last move (decides how a page comes in).
    private(set) var previousScreen: Screen = .firstRun
    @Published var show: Show? { didSet { syncTriggers(); keepSetReady() } }
    @Published var packageURL: URL?
    @Published var issues: [ShowIssue] = []
    @Published var currentSongID: UUID? {
        didSet {
            syncTriggers()
            keepSetReady()
            if currentSongID != oldValue {
                selectedMarkerIDs = []
                timelineWindow = TimelineWindow(length: currentSong?.playLength ?? 1)
            }
        }
    }
    /// The markers and triggers picked in the timeline (Delete removes them, ⌥← ⌥→ nudge them).
    @Published var selectedMarkerIDs: Set<UUID> = []
    /// One selected marker (setting it selects just that one).
    var selectedMarkerID: UUID? {
        get { selectedMarkerIDs.count == 1 ? selectedMarkerIDs.first : nil }
        set { selectedMarkerIDs = newValue.map { [$0] } ?? [] }
    }
    /// Marker edits that ⌘Z can take back: the song's markers before each change.
    private var markerUndo: [(songID: UUID, markers: [Marker])] = []
    private var markerRedo: [(songID: UUID, markers: [Marker])] = []
    /// The notice's Undo button takes back a marker change.
    @Published var noticeOffersMarkerUndo = false
    /// How far the timeline is zoomed in, and where.
    @Published var timelineWindow = TimelineWindow(length: 1)
    /// Where the timeline's tracks sit in the window (top-left coordinates), for trackpad zoom.
    var timelineTrackFrame: CGRect = .zero
    /// The timeline has more lanes than fit, and scrolls up and down.
    var timelineScrolls = false
    private var eventMonitor: Any?
    /// The executor lane C adds triggers to.
    @Published var selectedLaneID: UUID?
    /// The lane being edited (a new one has no saved copy yet).
    @Published var laneEdit: TriggerLane?
    /// A text field in the window has focus (single-key shortcuts stand aside).
    @Published var typingInField = false
    /// A section of Connections to scroll to when it opens ("consoles").
    var connectionsAnchor: String?
    @Published var showsShowTimecode = true
    @Published var importState: ImportState = .idle
    @Published var waveforms: [UUID: WaveformData] = [:]
    @Published var issuesShown = false
    @Published var outputShown = false
    @Published var setlistEditorShown = false
    @Published var goToShown = false
    @Published var markerEdit: MarkerEdit?
    @Published var selectedSetlistID: UUID? { didSet { keepSetReady() } }
    /// Show mode: playback only, nothing can be edited.
    @Published var locked = false
    @Published var stopAfterEach = UserDefaults.standard.bool(forKey: "stopAfterEach") {
        didSet { UserDefaults.standard.set(stopAfterEach, forKey: "stopAfterEach") }
    }
    @Published var devices: [AudioDevice] = []
    /// A short message after adding or changing files; clears itself.
    @Published var notice: String?
    @Published var lastSaved: Date?
    @Published var lastFix: FixUndo?
    /// How the song list is shown. Playback always follows the setlist order.
    @Published var sort: SetlistSort = .setlist
    /// Every saved show, for the Albums page.
    @Published var library: [ShowLibrary.Entry] = []
    @Published var showInfoShown = false
    /// Leave skipped songs out of the list entirely.
    @Published var hideSkipped = UserDefaults.standard.bool(forKey: "hideSkipped") {
        didSet { UserDefaults.standard.set(hideSkipped, forKey: "hideSkipped") }
    }
    /// The notice offers Undo (for the fix it reports).
    @Published var noticeOffersUndo = false
    /// An Undo for the notice that isn't a fix or a marker change (deleting an album).
    var noticeUndoAction: (() -> Void)?
    /// The Add Album sheet (the same import options as a new show).
    @Published var addAlbumShown = false
    /// Show Info for an album that isn't the open show.
    @Published var showInfoEntry: ShowLibrary.Entry?
    /// Where Cancel on the import screen goes back to, when a show is already open.
    @Published var importReturn: Screen?

    let transport = Transport()
    lazy var control = ControlCenter(clock: transport.clock)
    lazy var meters = MeterModel(state: transport.audio.state)
    private let reader = AVAudioFileReader()

    init() {
        transport.onSongEnd = { [weak self] in self?.advanceAfterSongEnd() }
        transport.wantedNext = { [weak self] in
            // Recording from the desk stays on the selected song: it stops at the end instead of
            // running on into the next one.
            guard let self, !self.stopAfterEach, !self.recordingFromDesk else { return nil }
            return self.nextSong
        }
        transport.onAdvance = { [weak self] song in self?.ranOn(into: song) }
        control.onCommand = { [weak self] in self?.handle($0) }
        control.onFollow = { [weak self] in self?.follow($0) }
        control.followContext = { [weak self] in
            guard let self else { return ([], nil, 0, false) }
            return (self.queue, self.currentSong?.id, self.transport.position(), self.transport.isPlaying)
        }
        control.followRate = { [weak self] in self?.show?.defaultRate ?? .fps30 }
        control.onTriggerSettingsChange = { [weak self] in self?.syncTriggers() }
        control.onDeskGo = { [weak self] go, at in self?.deskGo(go, arrivedAt: at) }
        control.onDeskSequence = { [weak self] event, at in self?.deskSequence(event, arrivedAt: at) }
        control.onDeskLabel = { [weak self] label in self?.deskLabel(label) }
        // Whatever's still waiting to be saved is written before the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave(wait: true) }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
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
    var sheetOpen: Bool { issuesShown || outputShown || setlistEditorShown || goToShown || markerEdit != nil || showInfoShown || laneEdit != nil || typingInField || addAlbumShown || showInfoEntry != nil || labelsShown }

    static var showsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Vivid Playback")
    }

    // MARK: Albums and the song list order

    /// The setlist's songs as the list shows them (sorted for viewing, or in setlist order).
    var visibleSongs: [Song] {
        guard let show, let setlist else { return setlistSongs }
        let ids = setlist.songIDs(sortedBy: sort, in: show).filter { !(hideSkipped && setlist.skipped.contains($0)) }
        return ids.compactMap(show.song(id:))
    }

    func refreshLibrary() {
        let folder = Self.showsFolder
        Task {
            let entries = await Task.detached(priority: .utility) { ShowLibrary.list(in: folder) }.value
            self.library = entries
        }
    }

    /// Opens a setlist from the Albums page (loading its show first if it isn't open).
    func openAlbum(_ entry: ShowLibrary.Entry, setlistID: UUID) {
        if packageURL?.standardizedFileURL != entry.url.standardizedFileURL {
            guard !transport.isPlaying else { post("Stop playback before opening another show."); return }
            open(package: entry.url)
        }
        if let list = show?.setlists.first(where: { $0.id == setlistID }) { select(setlist: list) }
        sort = .setlist
        go(.library)
    }

    // MARK: Adding and deleting albums

    /// Add Album: the new-show import options, in a sheet over the Albums page.
    func addAlbum() {
        guard !locked else { return }
        if case .finished = importState {} else if case .running = importState {} else { importState = .idle }
        addAlbumShown = true
    }

    /// Deletes one album. A show with other setlists keeps its songs and loses this setlist; a
    /// show's last album takes the show file with it, to the Trash. Either way Undo puts it back.
    func deleteAlbum(_ entry: ShowLibrary.Entry, setlistID: UUID) {
        guard !locked else { return }
        let isCurrent = entry.url.standardizedFileURL == packageURL?.standardizedFileURL
        let current = isCurrent ? (show ?? entry.show) : entry.show
        guard let index = current.setlists.firstIndex(where: { $0.id == setlistID }) else { return }
        let removed = current.setlists[index]
        if isCurrent && transport.isPlaying && setlist?.id == setlistID {
            post("Stop playback before deleting the album that's playing.")
            return
        }
        if current.setlists.count > 1 {
            var target = current
            target.setlists.remove(at: index)
            apply(target, to: entry.url, isCurrent: isCurrent)
            if isCurrent, selectedSetlistID == setlistID { selectedSetlistID = target.setlists.first?.id }
            refreshLibrary()
            postUndo("Deleted \(removed.name).") { [weak self] in
                guard let self else { return }
                let now = entry.url.standardizedFileURL == self.packageURL?.standardizedFileURL
                guard var back = now ? self.show : (try? ShowStore.load(from: entry.url)) else { return }
                back.setlists.insert(removed, at: min(index, back.setlists.count))
                self.apply(back, to: entry.url, isCurrent: now)
                self.refreshLibrary()
            }
            return
        }
        // The show's only album: the show goes to the Trash.
        if isCurrent {
            guard !transport.isPlaying else { post("Stop playback before deleting the show that's playing."); return }
            save()
        }
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &trashed)
        } catch {
            post("Couldn't move \(entry.url.lastPathComponent) to the Trash: \(error.localizedDescription)")
            return
        }
        if isCurrent { closeShow() }
        library.removeAll { $0.url.standardizedFileURL == entry.url.standardizedFileURL }
        refreshLibrary()
        let name = current.name
        postUndo("Moved \(name) to the Trash.") { [weak self] in
            guard let self, let from = trashed.map({ $0 as URL }) else { return }
            do {
                try FileManager.default.moveItem(at: from, to: entry.url)
                self.refreshLibrary()
                if self.show == nil { self.open(package: entry.url); self.go(.albums) }
            } catch {
                self.post("Couldn't bring \(name) back. It's in the Trash.")
            }
        }
    }

    /// Add Album › Open show file…: pick a .vividshow to add to Albums.
    func chooseShowFileForAlbums() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add to Albums"
        panel.message = "Choose a Vivid Playback show (.vividshow)."
        if panel.runModal() == .OK, let url = panel.url { addShowFile(url) }
    }

    /// Copies a show file into ~/Documents/Vivid Playback so it appears in Albums. The original
    /// (on a USB stick, say) is left as it is.
    func addShowFile(_ url: URL) {
        guard url.pathExtension == ShowStore.fileExtension, let show = try? ShowStore.load(from: url) else {
            importState = .failed("\(url.lastPathComponent) isn't a Vivid Playback show. Drop a show folder to import one.")
            return
        }
        let inLibrary = url.deletingLastPathComponent().standardizedFileURL == Self.showsFolder.standardizedFileURL
        if !inLibrary {
            let dest = newPackage(for: show)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                importState = .failed("Couldn't copy \(url.lastPathComponent): \(error.localizedDescription)")
                return
            }
        }
        importState = .idle
        addAlbumShown = false
        refreshLibrary()
        go(.albums)
        post(inLibrary ? "\(show.name) is already in Albums." : "Added \(show.name) to Albums.")
    }

    /// Saves a changed show, to the open show or to its package on disk.
    private func apply(_ target: Show, to package: URL, isCurrent: Bool) {
        if isCurrent {
            show = target
            save()
        } else {
            try? ShowStore.save(target, to: package)
        }
    }

    /// Closes the open show (after its file went to the Trash): another saved show opens if there
    /// is one, otherwise the import screen.
    private func closeShow() {
        dropPendingSave()
        transport.pause()
        UserDefaults.standard.removeObject(forKey: "lastShowPath")
        let others = library.filter { $0.url.standardizedFileURL != packageURL?.standardizedFileURL }
        if let next = others.first {
            open(package: next.url)
            go(.albums)
        } else {
            show = nil
            packageURL = nil
            currentSongID = nil
            issues = []
            importState = .idle
            importReturn = nil
            go(.firstRun)
        }
    }

    private func postUndo(_ text: String, _ action: @escaping () -> Void) {
        post(text)
        noticeUndoAction = action
    }

    func runNoticeUndo() {
        let action = noticeUndoAction
        noticeUndoAction = nil
        withAnimation(.vivid(0.3)) { notice = nil }
        action?()
    }

    private func editSetlist(_ change: (inout Setlist) -> Void) {
        guard var list = setlist else { return }
        change(&list)
        updateSetlist(list)
    }

    /// Reorders by drag or menu. Only in setlist order: in a sorted view "before" is ambiguous.
    func moveSongs(_ ids: [UUID], before target: UUID?) {
        guard sort == .setlist else { post("Switch the list back to setlist order to move songs."); return }
        editSetlist { $0.move(ids, before: target) }
    }

    func removeFromSetlist(_ song: Song) {
        guard !(transport.isPlaying && currentSong?.id == song.id) else {
            post("\(song.title) is playing. Stop it before taking it out of the setlist.")
            return
        }
        let name = setlist?.name ?? "the setlist"
        editSetlist { $0.remove(song.id) }
        post("\(song.title) is out of \(name). It's still in the show: add it back in Edit Setlist.")
    }

    func moveUp(_ song: Song) { guard sort == .setlist else { return }; editSetlist { $0.moveUp(song.id) } }
    func moveDown(_ song: Song) { guard sort == .setlist else { return }; editSetlist { $0.moveDown(song.id) } }
    func moveToTop(_ song: Song) { moveSongs([song.id], before: setlist?.songIDs.first) }
    func moveToBottom(_ song: Song) { moveSongs([song.id], before: nil) }

    /// Makes the current sort the setlist's order.
    func saveSortedOrder() {
        guard let show, var list = setlist, sort != .setlist else { return }
        list.songIDs = list.songIDs(sortedBy: sort, in: show)
        updateSetlist(list)
        sort = .setlist
        post("\(list.name) now plays in this order.")
    }

    /// Cover art for a setlist of the open show, or of another saved show.
    func setArtwork(_ image: URL?, for setlistID: UUID, in entry: ShowLibrary.Entry? = nil) {
        guard !locked else { return }
        let package = entry?.url ?? packageURL
        guard let package else { return }
        let isCurrent = package.standardizedFileURL == packageURL?.standardizedFileURL
        guard var target = isCurrent ? show : (try? ShowStore.load(from: package)),
              let i = target.setlists.firstIndex(where: { $0.id == setlistID }) else { return }
        if let image {
            guard let path = try? ShowLibrary.storeArtwork(image, for: target.setlists[i], in: package) else {
                post("Couldn't use \(image.lastPathComponent) as a cover.")
                return
            }
            target.setlists[i].artwork = path
        } else {
            target.setlists[i].artwork = nil
        }
        if isCurrent {
            show = target
            save()
        } else {
            try? ShowStore.save(target, to: package)
        }
        refreshLibrary()
    }

    func chooseArtwork(for setlistID: UUID, in entry: ShowLibrary.Entry? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use as Cover"
        if panel.runModal() == .OK, let url = panel.url { setArtwork(url, for: setlistID, in: entry) }
    }

    func updateShowInfo(artist: String, name: String) {
        let a = artist.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        edit { show in
            show.artist = a.isEmpty ? nil : a
            if !n.isEmpty { show.name = n }
        }
        refreshLibrary()
    }

    /// Show Info for an album on the Albums page (the open show or another saved one).
    func updateShowInfo(_ entry: ShowLibrary.Entry, artist: String, name: String) {
        guard !locked else { return }
        if entry.url.standardizedFileURL == packageURL?.standardizedFileURL {
            updateShowInfo(artist: artist, name: name)
            return
        }
        guard var target = try? ShowStore.load(from: entry.url) else { return }
        let a = artist.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        target.artist = a.isEmpty ? nil : a
        if !n.isEmpty { target.name = n }
        try? ShowStore.save(target, to: entry.url)
        refreshLibrary()
    }

    /// Every artist in the library, for the artist pickers.
    var knownArtists: [String] {
        var entries = library
        if let show, let packageURL { entries.append(ShowLibrary.Entry(url: packageURL, show: show)) }
        return ShowLibrary.artists(in: entries)
    }

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

    /// Findings still showing (warnings Caiden hid are left out).
    var activeIssues: [ShowIssue] { issues.filter { !(show?.isDismissed($0) ?? false) } }
    var hiddenIssues: [ShowIssue] { issues.filter { show?.isDismissed($0) ?? false } }
    func issues(for song: Song) -> [ShowIssue] { activeIssues.filter { $0.songID == song.id } }
    func hiddenIssues(for song: Song) -> [ShowIssue] { hiddenIssues.filter { $0.songID == song.id } }

    /// Hiding a warning changes nothing about playback, so it's allowed in show mode too.
    /// Applied just after the click, without animation: the button that was clicked may vanish.
    func dismiss(_ issue: ShowIssue) {
        guard issue.canDismiss else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, var show = self.show else { return }
            show.dismiss(issue)
            self.show = show
            self.save()
        }
    }

    func restore(_ issue: ShowIssue) {
        DispatchQueue.main.async { [weak self] in
            guard let self, var show = self.show else { return }
            show.restore(issue)
            self.show = show
            self.save()
        }
    }

    func cue(_ song: Song, play: Bool? = nil, at position: Double? = nil) {
        guard let show else { return }
        currentSongID = song.id
        transport.load(song, in: show, play: play, at: position)
        loadWaveform(for: song)
    }

    /// The audio ran straight on into the next song (no gap): the screen catches up with it.
    private func ranOn(into song: Song) {
        guard let show else { return }
        currentSongID = song.id
        if let fresh = show.song(id: song.id) { transport.update(fresh, in: show) }
        loadWaveform(for: song)
    }

    private var keepReadyQueued = false
    /// Hands the transport the set in the order it's needed, so every song is in memory and
    /// switching to it is instant. Batched: many changes in one moment hand it over once.
    func keepSetReady() {
        guard !keepReadyQueued else { return }
        keepReadyQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keepReadyQueued = false
            guard let show = self.show else { return }
            let order = SetMemory.order(queue: self.queue.map(\.id), all: show.songs.map(\.id), current: self.currentSong?.id)
            self.transport.keepReady(order.compactMap(show.song(id:)), in: show)
        }
    }

    /// Double-click in the song list: play this song from its top. The song already playing
    /// carries on rather than starting over.
    func playFromList(_ song: Song) {
        if currentSong?.id == song.id {
            if !transport.isPlaying { transport.play() }
        } else {
            cue(song, play: true)
        }
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

    /// How long a song plays: what's loaded for the cued song, else its audio's measured length,
    /// else the sheet's.
    func playLength(of song: Song) -> Double {
        if song.id == currentSong?.id, transport.length > 0 { return transport.length }
        return song.playLength ?? 0
    }

    /// The timecode at the playhead.
    func timecode(for song: Song, at position: Double) -> Timecode {
        song.start.adding(frames: Int((position * song.rate.framesPerSecond + 1e-6).rounded(.down)))
    }

    // MARK: Screens

    func go(_ target: Screen) {
        guard show != nil || target == .firstRun, target != screen else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The screens' own transitions set their timing (a quick fade out, then the new screen
        // settles in); this covers everything else that changes with the screen.
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.18) : .vivid(0.42)
        previousScreen = screen
        withAnimation(animation) { screen = target }
    }

    /// Cancel on the import screen: back where you were, with the open show.
    func cancelImport() {
        importState = .idle
        let back = importReturn ?? .library
        importReturn = nil
        go(back)
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

    func addMarker(remote: Bool = false) {
        guard screen == .timeline || remote, let song = currentSong else { return }
        rememberMarkers(of: song)
        let tc = timecode(for: song, at: transport.position())
        withAnimation(.vivid(0.45)) {
            edit { show in
                guard let i = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
                let marker = Marker(time: tc, label: "Marker \(show.songs[i].markers.filter { $0.laneID == nil }.count + 1)")
                show.songs[i].markers.append(marker)
                selectedMarkerID = marker.id
                show.songs[i].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
            }
        }
    }

    func renameMarker(_ marker: Marker, in song: Song, to label: String) {
        let text = label.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        rememberMarkers(of: song)
        edit { show in
            guard let s = show.songs.firstIndex(where: { $0.id == song.id }),
                  let m = show.songs[s].markers.firstIndex(where: { $0.id == marker.id }) else { return }
            show.songs[s].markers[m].label = text
        }
    }

    func deleteMarker(_ marker: Marker, in song: Song) {
        rememberMarkers(of: song)
        withAnimation(.vivid(0.4)) {
            edit { show in
                guard let s = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
                show.songs[s].markers.removeAll { $0.id == marker.id }
            }
        }
        selectedMarkerIDs.remove(marker.id)
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
        let points = song.markers.filter { $0.laneID == nil }.map { seconds(of: $0, in: song) }.sorted()
        let start = points.last(where: { $0 <= p }) ?? 0
        let end = points.first(where: { $0 > p }) ?? playLength(of: song)
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
        if before.deviceUID != show.routing.deviceUID || before.splitsInterfaces != show.routing.splitsInterfaces
            || (show.routing.splitsInterfaces && before.timecodeDeviceUID != show.routing.timecodeDeviceUID) {
            transport.configure(routing: show.routing)
            recheck()
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
            if offset >= -song.fileOffset && offset <= (song.playLength ?? 0) {
                if currentSong?.id != song.id { cue(song, play: false) }
                transport.locate(offset)
                return nil
            }
        }
        if Timecode(text, rate: show.defaultRate) == nil { return "That isn't a timecode. Use HH:MM:SS:FF." }
        return "No song in this setlist plays at \(text)."
    }

    // MARK: Executor lanes and triggers

    /// The current song's executor lanes (each song has its own).
    var lanes: [TriggerLane] { currentSong?.triggerLanes ?? [] }
    /// Every lane in the show, for the Consoles page.
    var allLanes: [TriggerLane] { show?.songs.flatMap { $0.triggerLanes ?? [] } ?? [] }
    /// Other songs with lanes, to copy from.
    var songsWithLanes: [Song] { show?.songs.filter { $0.id != currentSongID && !($0.triggerLanes ?? []).isEmpty } ?? [] }
    var selectedLane: TriggerLane? { lanes.first { $0.id == selectedLaneID } ?? lanes.first }

    /// Hands the current song's triggers to the firing queue.
    func syncTriggers() {
        control.triggers.update(song: currentSong, lanes: lanes, consoles: control.settings.consoles,
                                fireEarlyMs: control.settings.fireEarlyMs)
    }

    func newLane() {
        let next = (lanes.map(\.executor).max() ?? 200) + 1
        laneEdit = TriggerLane(page: lanes.last?.page ?? 1, executor: next, color: lanes.count % 6,
                               key: TriggerLane.freeKey(in: lanes))
    }

    func saveLane(_ lane: TriggerLane) {
        guard let song = currentSong else { return }
        edit { show in
            guard let s = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
            var list = show.songs[s].triggerLanes ?? []
            // A key belongs to one lane: giving it to this one takes it off any other.
            if let key = lane.key {
                for j in list.indices where list[j].id != lane.id && list[j].key == key { list[j].key = nil }
            }
            if let i = list.firstIndex(where: { $0.id == lane.id }) { list[i] = lane } else { list.append(lane) }
            show.songs[s].triggerLanes = list
        }
        selectedLaneID = lane.id
    }

    func deleteLane(_ lane: TriggerLane) {
        guard let song = currentSong else { return }
        edit { show in
            guard let s = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
            show.songs[s].triggerLanes?.removeAll { $0.id == lane.id }
            if show.songs[s].triggerLanes?.isEmpty == true { show.songs[s].triggerLanes = nil }
            show.songs[s].markers.removeAll { $0.laneID == lane.id }
        }
        if selectedLaneID == lane.id { selectedLaneID = lanes.first?.id }
    }

    /// Copies another song's lanes (not its triggers) onto this song, as new lanes. A lane whose
    /// executor and action this song already has is skipped; keys already in use are left off.
    func copyLanes(from source: Song) {
        guard let song = currentSong, !locked else { return }
        var list = lanes
        var added = 0
        for lane in source.triggerLanes ?? [] {
            if list.contains(where: { $0.page == lane.page && $0.executor == lane.executor && $0.action == lane.action }) { continue }
            var copy = lane.copy()
            if let key = copy.key, list.contains(where: { $0.key == key }) { copy.key = nil }
            list.append(copy)
            added += 1
        }
        guard added > 0 else { post("\(song.title) already has \(source.title)'s lanes."); return }
        withAnimation(.vivid(0.4)) {
            edit { show in
                guard let s = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
                show.songs[s].triggerLanes = list
            }
        }
        selectedLaneID = list.first?.id
        post("Copied \(added) lane\(added == 1 ? "" : "s") from \(source.title).")
    }

    func toggleMute(_ lane: TriggerLane) {
        var l = lane
        l.muted.toggle()
        saveLane(l)
    }

    /// C in the timeline: a trigger at the playhead on the selected lane (or, with `at`, on
    /// `lane` at that point in the song: double-clicking a lane).
    @discardableResult
    func addTrigger(on target: TriggerLane? = nil, at seconds: Double? = nil) -> Marker? {
        guard screen == .timeline, !locked, currentSong != nil else { return nil }
        guard let lane = target ?? selectedLane else { newLane(); return nil }
        return insertTrigger(on: lane, at: seconds ?? transport.position())
    }

    /// A trigger on `lane` in the current song, `seconds` from its start (any screen).
    @discardableResult
    private func insertTrigger(on lane: TriggerLane, at seconds: Double, label: String? = nil,
                               action: LaneAction? = nil, value: Double? = nil) -> Marker? {
        guard !locked, let song = currentSong else { return nil }
        rememberMarkers(of: song)
        if !recordingFromDesk { selectedLaneID = lane.id }
        let tc = timecode(for: song, at: max(0, seconds))
        let count = song.markers.filter { $0.laneID == lane.id }.count + 1
        let marker = Marker(time: tc, label: label ?? (lane.action == .fader ? "Level" : "\(lane.action.label) \(count)"),
                            laneID: lane.id, value: value ?? (lane.action == .fader ? 100 : nil), action: action)
        let insert = {
            self.edit { show in
                guard let i = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
                show.songs[i].markers.append(marker)
                show.songs[i].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
            }
        }
        // Recording from the desk brings triggers fast: no animation and no selection, so the
        // timeline stays smooth.
        if recordingFromDesk {
            insert()
        } else {
            withAnimation(.vivid(0.35)) { insert() }
            selectedMarkerID = marker.id
        }
        return marker
    }

    func updateMarker(_ marker: Marker, in song: Song, _ change: (inout Marker) -> Void) {
        rememberMarkers(of: song)
        edit { show in
            guard let s = show.songs.firstIndex(where: { $0.id == song.id }),
                  let m = show.songs[s].markers.firstIndex(where: { $0.id == marker.id }) else { return }
            change(&show.songs[s].markers[m])
            show.songs[s].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
        }
    }

    func setLevel(_ marker: Marker, in song: Song, to level: Double) {
        updateMarker(marker, in: song) { $0.value = max(0, min(100, level.rounded())) }
    }

    func move(_ marker: Marker, in song: Song, to seconds: Double) {
        var target = seconds
        if snapToGrid, let grid = song.beatGrid { target = grid.snap(seconds, to: snapDivision) }
        let tc = timecode(for: song, at: max(0, min(target, playLength(of: song))))
        updateMarker(marker, in: song) { $0.time = tc }
    }

    func nudge(_ marker: Marker, in song: Song, frames: Int) {
        updateMarker(marker, in: song) { $0.time = $0.time.adding(frames: frames) }
    }

    func moveToPlayhead(_ marker: Marker, in song: Song) {
        let tc = timecode(for: song, at: transport.position())
        updateMarker(marker, in: song) { $0.time = tc }
    }

    func fire(_ marker: Marker) {
        guard let lane = lanes.first(where: { $0.id == marker.laneID }) else { return }
        control.triggers.fire(lane: lane, marker: marker)
        control.flash(marker.id, lane: lane.id)
    }

    func fireLane(_ lane: TriggerLane) {
        control.triggers.fire(lane: lane, marker: nil)
        control.flash(nil, lane: lane.id)
    }

    // MARK: Record from the desk

    /// Armed: every GO from the desk (OSC /vivid/exec, or MIDI Show Control) lands as a trigger on
    /// that executor's lane, at the frame you hear, while the song plays.
    @Published private(set) var recordingFromDesk = false
    /// The last GO heard from the desk, and what became of it.
    @Published private(set) var lastDeskGo: (text: String, at: Date)?

    func toggleDeskRecording() {
        guard !locked || recordingFromDesk else { return }
        recordingFromDesk.toggle()
        control.listenForDesk(recordingFromDesk)
        if recordingFromDesk {
            let osc = control.settings.oscIn ? "OSC /vivid/exec on port \(control.settings.oscPort)" : "OSC (turn on OSC in under Connections)"
            post("Recording from the desk onto \(currentSong?.title ?? "the selected song"): the Vivid Recorder plugin or \(osc), and MIDI Show Control over MIDI or port \(control.settings.mscPort). It stops at the end of the song. Play it and fire away.")
        }
    }

    /// A sequence on the desk changed cue (the Vivid Recorder plugin, which only watches the
    /// fader page the desk is on). Recorded onto the selected song, on that executor's lane, as
    /// what the sequence did: Go+, Go-, Top, Goto a cue, On or Off.
    func deskSequence(_ e: DeskSequenceEvent, arrivedAt: Double = CACurrentMediaTime()) {
        let from = "\(e.page).\(e.executor) \(e.action.label)\(e.isOn && e.cue != nil ? " cue \(TriggerLane.cueText(e.cue!))" : "")"
        guard recordingFromDesk else { lastDeskGo = ("\(from) · not recording", Date()); return }
        guard !locked, currentSong != nil else { lastDeskGo = ("\(from) · nothing selected", Date()); return }
        guard transport.isPlaying else { lastDeskGo = ("\(from) · play the song to record it", Date()); return }
        // Where it happened: the desk's own stamp put on this Mac's clock (or the moment it
        // arrived), then where the music was at that moment.
        var when = deskClock.time(desk: e.deskTime, arrivedAt: arrivedAt)
        if e.deskTime != nil { when -= DeskSequenceEvent.detectionLag }
        guard armedForRecording(page: e.page, executor: e.executor) else {
            lastDeskGo = ("\(from) · not armed", Date())
            return
        }
        // Vivid's own trigger making the desk move isn't a press.
        if control.triggers.isEcho(page: e.page, executor: e.executor, at: when) {
            lastDeskGo = ("\(from) · Vivid fired that, not recorded", Date())
            return
        }
        deskQueue.append((e, transport.position(at: when)))
        guard !deskFlushQueued else { return }
        deskFlushQueued = true
        // Everything that arrives in the same moment lands in one edit: one redraw, one undo.
        DispatchQueue.main.async { [weak self] in self?.flushDeskQueue() }
    }

    private var deskClock = DeskClock()

    /// Executors armed for recording ("3.201"). While any are armed, only they record from the
    /// desk, so a timecode show running on the desk can move everything else. None armed:
    /// everything records.
    @Published var armedExecutors: Set<String> = []

    func isArmed(_ lane: TriggerLane) -> Bool { armedExecutors.contains("\(lane.page).\(lane.executor)") }

    func toggleArm(_ lane: TriggerLane) {
        let key = "\(lane.page).\(lane.executor)"
        if armedExecutors.contains(key) { armedExecutors.remove(key) } else { armedExecutors.insert(key) }
    }

    func armAll(_ on: Bool) {
        armedExecutors = on ? Set(lanes.map { "\($0.page).\($0.executor)" }) : []
    }

    /// Whether a hit on this executor records, given what's armed.
    private func armedForRecording(page: Int?, executor: Int) -> Bool {
        guard !armedExecutors.isEmpty else { return true }
        if let page { return armedExecutors.contains("\(page).\(executor)") }
        return armedExecutors.contains { $0.hasSuffix(".\(executor)") }
    }
    private var deskQueue: [(event: DeskSequenceEvent, seconds: Double)] = []
    private var deskFlushQueued = false

    private func flushDeskQueue() {
        deskFlushQueued = false
        let items = deskQueue
        deskQueue = []
        guard !items.isEmpty, !locked, let song = currentSong else { return }
        rememberMarkers(of: song)
        // A hit right on a trigger that was already there is the desk echoing what Vivid just
        // fired, not a new one.
        let before = song.markers
        var flashes: [(marker: UUID, lane: UUID)] = []
        var last = ""
        var skipped = 0
        edit { show in
            guard let si = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
            var lanes = show.songs[si].triggerLanes ?? []
            for (e, seconds) in items {
                let found = lanes.firstIndex { $0.page == e.page && $0.executor == e.executor }
                if found == nil {
                    lanes.append(TriggerLane(page: e.page, executor: e.executor, color: lanes.count % 6,
                                             key: TriggerLane.freeKey(in: lanes)))
                }
                let lane = lanes[found ?? lanes.count - 1]
                let tc = timecode(for: song, at: max(0, seconds))
                let frame = tc.frames(since: song.start)
                let existing = before.filter { $0.laneID == lane.id }.map { $0.time.frames(since: song.start) }
                if DeskRecorder.isDuplicate(frame: frame, existing: existing) { skipped += 1; continue }
                let action = e.action
                let m = Marker(time: tc, label: e.label, laneID: lane.id,
                               value: action == .gotoCue ? e.cue : nil, action: action == lane.action ? nil : action)
                show.songs[si].markers.append(m)
                flashes.append((m.id, lane.id))
                last = "\(e.page).\(e.executor) \(action.label) → \(lane.title) at \(tc)"
            }
            show.songs[si].triggerLanes = lanes.isEmpty ? nil : lanes
            show.songs[si].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
        }
        for f in flashes { control.flash(f.marker, lane: f.lane) }
        let n = flashes.count
        if n > 1 {
            lastDeskGo = ("\(n) hits at once · \(last)\(skipped > 0 ? " · \(skipped) already there" : "")", Date())
        } else if n == 1 {
            lastDeskGo = (last, Date())
        } else if skipped > 0 {
            lastDeskGo = ("already on the lane here", Date())
        }
    }

    /// Names arriving from the desk's Vivid Labels plugin, gathered so one notice (with one Undo)
    /// covers the whole page.
    private var labelBatch: (before: [UUID: [TriggerLane]], lanes: Int, songs: Set<UUID>, unmatched: [String])?
    private var labelBatchTimer: Timer?

    /// The desk sent a sequence's name: every lane that fires that executor, in every song of the
    /// show, takes it.
    func deskLabel(_ label: DeskLabel) {
        guard !locked, var show else { return }
        if labelBatch == nil {
            var before: [UUID: [TriggerLane]] = [:]
            for s in show.songs { if let l = s.triggerLanes { before[s.id] = l } }
            labelBatch = (before, 0, [], [])
        }
        let beforeSongs = show.songs
        let result = label.apply(to: &show.songs)
        if result.lanes > 0 {
            for (old, new) in zip(beforeSongs, show.songs) where old.triggerLanes != new.triggerLanes {
                labelBatch?.songs.insert(new.id)
            }
            labelBatch?.lanes += result.lanes
            self.show = show
            if let song = currentSong { transport.update(song, in: show) }
            save()
        } else if !show.songs.contains(where: { ($0.triggerLanes ?? []).contains { $0.page == label.page && $0.executor == label.executor } }) {
            labelBatch?.unmatched.append("\(label.page).\(label.executor)")
        }
        labelBatchTimer?.invalidate()
        labelBatchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishLabelBatch() }
        }
    }

    private func finishLabelBatch() {
        guard let batch = labelBatch else { return }
        labelBatch = nil
        var text = batch.lanes == 0
            ? "The desk's names are already on the lanes."
            : "Named \(batch.lanes) lane\(batch.lanes == 1 ? "" : "s") after the desk's sequences, in \(batch.songs.count) song\(batch.songs.count == 1 ? "" : "s")."
        if !batch.unmatched.isEmpty {
            let list = batch.unmatched.prefix(4).joined(separator: ", ") + (batch.unmatched.count > 4 ? "…" : "")
            text += " No lane fires \(list) yet."
        }
        guard batch.lanes > 0 else { post(text); return }
        postUndo(text) { [weak self] in
            guard let self, !self.locked, var show = self.show else { return }
            for i in show.songs.indices where batch.songs.contains(show.songs[i].id) {
                show.songs[i].triggerLanes = batch.before[show.songs[i].id]
            }
            self.show = show
            if let song = self.currentSong { self.transport.update(song, in: show) }
            self.save()
        }
    }

    /// Sets what the given triggers do: nil does what their lane does. `value` is the cue for
    /// Goto (or {value} for Custom); `command` the word (Desk command) or line (Custom).
    func setTriggerAction(_ ids: Set<UUID>, to action: LaneAction?, value: Double? = nil, command: String? = nil) {
        guard let song = currentSong, !locked, !ids.isEmpty else { return }
        rememberMarkers(of: song)
        let lanesByID = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        edit { show in
            guard let s = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
            for m in show.songs[s].markers.indices where ids.contains(show.songs[s].markers[m].id) {
                let laneAction = show.songs[s].markers[m].laneID.flatMap { lanesByID[$0]?.action }
                let own = action == laneAction && action != .command && action != .custom ? nil : action
                show.songs[s].markers[m].action = own
                show.songs[s].markers[m].command = (own == .command || own == .custom) ? command : nil
                if own == .gotoCue || own == .custom { show.songs[s].markers[m].value = value ?? show.songs[s].markers[m].value }
            }
        }
    }

    /// The triggers a menu acts on: the whole selection when the clicked one is in it.
    func triggerTargets(_ m: Marker) -> Set<UUID> {
        selectedMarkerIDs.count > 1 && selectedMarkerIDs.contains(m.id) ? selectedMarkerIDs : [m.id]
    }

    /// Imports grandMA3 timecode shows (their exported XML) as lanes and triggers: each show onto
    /// its song (by name, else by timecode, else the selected song), one lane per track firing its
    /// sequence, one trigger per event, placed by timecode. One notice, one Undo.
    func importMA3Timecode() {
        guard !locked, show != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.xml]
        panel.prompt = "Import"
        panel.message = "Choose grandMA3 timecode exports (XML), one per song."
        guard panel.runModal() == .OK else { return }
        importMA3Timecode(panel.urls)
    }

    func importMA3Timecode(_ urls: [URL]) {
        guard !locked, var show else { return }
        let before = show.songs
        var lines: [String] = []
        var imported = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                lines.append("\(url.lastPathComponent): couldn't be read.")
                continue
            }
            let shows = MA3Timecode.parse(data)
            if shows.isEmpty { lines.append("\(url.lastPathComponent): no timecode show in it.") }
            for tc in shows {
                guard let target = MA3TimecodeImport.song(for: tc, in: show.songs, selected: currentSong?.id),
                      let i = show.songs.firstIndex(where: { $0.id == target.id }) else {
                    lines.append("\(tc.name): no song to put it on. Select one and import again.")
                    continue
                }
                let r = MA3TimecodeImport.apply(tc, to: &show.songs[i])
                imported += r.triggers
                let title = show.songs[i].title
                var line = "\(tc.name) → \(title)"
                switch target.match {
                case .name: break
                case .timecode: line += " (by its timecode)"
                case .selected: line += " (the selected song: no song is named \(tc.name) or plays at its timecode)"
                }
                if r.triggers == 0 {
                    line += ": nothing new"
                } else {
                    line += ": \(r.triggers) new trigger\(r.triggers == 1 ? "" : "s")"
                    if r.lanesAdded > 0 { line += ", \(r.lanesAdded) new lane\(r.lanesAdded == 1 ? "" : "s")" }
                }
                line += "."
                if r.alreadyImported > 0 { line += " \(r.alreadyImported) imported before, left as they are here." }
                if r.outside > 0 { line += " \(r.outside) fall outside the song, left out." }
                if r.unreadable > 0 { line += " \(r.unreadable) had no command, left out." }
                if tc.otherTracks > 0 { line += " \(tc.otherTracks) track\(tc.otherTracks == 1 ? "" : "s") fire something other than a sequence, left out." }
                if abs(r.startDifference) >= 1 / show.songs[i].rate.framesPerSecond {
                    let showStart = Timecode(frameCount: Int((tc.offset * show.songs[i].rate.framesPerSecond).rounded()), rate: show.songs[i].rate)
                    line += " The desk's show starts at \(showStart), the song at \(show.songs[i].start): placed by timecode."
                }
                lines.append(line)
            }
        }
        guard imported > 0 || before != show.songs else {
            post(lines.isEmpty ? "Nothing to import." : lines.joined(separator: " "))
            return
        }
        self.show = show
        if let song = currentSong { transport.update(song, in: show) }
        save()
        postUndo(lines.joined(separator: " ")) { [weak self] in
            guard let self, !self.locked, var now = self.show else { return }
            let restore = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            for j in now.songs.indices {
                if let old = restore[now.songs[j].id] {
                    now.songs[j].markers = old.markers
                    now.songs[j].triggerLanes = old.triggerLanes
                }
            }
            self.show = now
            if let song = self.currentSong { self.transport.update(song, in: now) }
            self.save()
        }
    }

    /// Writes the grandMA3 plugins (Vivid Recorder and Vivid Labels, each an XML and a Lua) into a
    /// folder, for a USB stick's grandMA3_library/plugins.
    func saveDeskPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save the grandMA3 plugins. On a USB stick for the desk: grandMA3_library › plugins."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            for f in DeskPlugin.allFiles(oscLine: 1) {
                try f.contents.write(to: folder.appendingPathComponent(f.name), atomically: true, encoding: .utf8)
            }
            post("Saved Vivid Recorder (run to start recording, again to stop) and Vivid Labels (run on a page to name the lanes after its sequences). Both send on OSC line 1; change OSC_LINE at the top of each .lua if yours is another.")
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("\(DeskPlugin.name).xml")])
        } catch {
            post("Couldn't save the plugin: \(error.localizedDescription)")
        }
    }

    /// The command for a desk macro that selects this song in Vivid Playback.
    func deskCommand(for song: Song) -> String {
        if let n = song.number { return "SendOSC 1 \"/vivid/song,i,\(n)\"" }
        let title = song.title.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ",", with: " ")
        return "SendOSC 1 \"/vivid/song,s,\(title)\""
    }

    func copyDeskCommand(for song: Song) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deskCommand(for: song), forType: .string)
        post("Copied \(deskCommand(for: song)). Put it in the song's macro on the desk (OSC in must be on here).")
    }

    func deskGo(_ go: DeskGo, arrivedAt: Double = CACurrentMediaTime()) {
        let from = "\(go.source.rawValue) GO \(go.label)\(go.cue.map { " cue \($0)" } ?? "")"
        guard recordingFromDesk else { lastDeskGo = ("\(from) · not recording", Date()); return }
        guard !locked, currentSong != nil else { lastDeskGo = ("\(from) · nothing cued", Date()); return }
        guard transport.isPlaying else { lastDeskGo = ("\(from) · play the song to record it", Date()); return }
        // Where the music was when the GO arrived (the position you hear), not when the screen got to it.
        let seconds = transport.position(at: arrivedAt)
        guard armedForRecording(page: go.page, executor: go.executor) else {
            lastDeskGo = ("\(from) · not armed", Date())
            return
        }
        if let page = go.page, control.triggers.isEcho(page: page, executor: go.executor, at: arrivedAt) {
            lastDeskGo = ("\(from) · Vivid fired that, not recorded", Date())
            return
        }
        var lane = DeskRecorder.lane(for: go, in: lanes)
        if lane == nil {
            // An executor with no lane yet gets one.
            let made = TriggerLane(page: go.page ?? 1, executor: go.executor, color: lanes.count % 6,
                                   key: TriggerLane.freeKey(in: lanes))
            saveLane(made)
            lane = made
        }
        guard let lane, let fresh = currentSong else { return }
        let frame = timecode(for: fresh, at: max(0, seconds)).frames(since: fresh.start)
        let existing = fresh.markers.filter { $0.laneID == lane.id }.map { $0.time.frames(since: fresh.start) }
        if DeskRecorder.isDuplicate(frame: frame, existing: existing) {
            lastDeskGo = ("\(from) · already on \(lane.title) here", Date())
            return
        }
        guard let marker = insertTrigger(on: lane, at: seconds, label: go.cue.map { "Cue \($0)" }) else { return }
        control.flash(marker.id, lane: lane.id)
        lastDeskGo = ("\(from) → \(lane.title) at \(marker.time)", Date())
    }

    // MARK: Import labels to console

    @Published var labelsShown = false

    /// Every lane in the open album (the current setlist's songs), for naming executors.
    var albumLanes: [TriggerLane] {
        guard let show else { return [] }
        let ids = setlist?.songIDs ?? show.songs.map(\.id)
        return ids.compactMap(show.song(id:)).flatMap { $0.triggerLanes ?? [] }
    }

    /// Names each executor's sequence after its lanes, on the consoles those lanes fire.
    func sendLabels(_ labels: [ExecutorLabel], done: @escaping (Int, Int) -> Void) {
        let consoles = control.settings.consoles
        let template = control.settings.labelTemplate
        let items = labels.map { (command: $0.command(template: template), consoles: $0.targets(in: consoles)) }
            .filter { !$0.consoles.isEmpty }
        control.triggers.sendCommands(items) { [weak self] sent, failed in
            done(sent, failed)
            self?.post(failed == 0 ? "Sent \(labels.count) label\(labels.count == 1 ? "" : "s") to the console."
                                   : "\(failed) label command\(failed == 1 ? "" : "s") couldn't leave this Mac. Check the network and Local Network access.")
        }
    }

    // MARK: Timeline keys, zoom and selection

    var selectedMarker: Marker? { currentSong?.markers.first { $0.id == selectedMarkerID } }

    /// Keys and trackpad gestures for the timeline. Returns true when the event was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard screen == .timeline, !sheetOpen, show != nil, event.window == NSApp.mainWindow || event.window?.isKeyWindow == true else { return false }
        switch event.type {
        case .keyDown: return handleKey(event)
        case .scrollWheel: return handleScroll(event)
        case .magnify: return handleMagnify(event)
        default: return false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if let field = event.window?.firstResponder as? NSTextView, field.isEditable { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // ⌥← ⌥→ nudge the selected marker a frame (with ⇧, ten frames).
        if event.keyCode == 123 || event.keyCode == 124, mods.contains(.option), !mods.contains(.command), !mods.contains(.control) {
            guard !locked, !selectedMarkerIDs.isEmpty else { return false }
            nudgeSelected(frames: (mods.contains(.shift) ? 10 : 1) * (event.keyCode == 123 ? -1 : 1))
            return true
        }
        // ⌘Z / ⇧⌘Z take back and redo marker changes; ⌘A selects every marker and trigger.
        if mods == .command || mods == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                if mods.contains(.shift) { return redoMarkers() }
                return undoMarkers()
            case "a" where mods == .command:
                selectAllMarkers()
                return true
            default:
                return false
            }
        }
        guard mods.subtracting(.shift).isEmpty else { return false }
        // Esc clears the selection first (then goes back to the library as usual).
        if event.keyCode == 53, !selectedMarkerIDs.isEmpty {
            selectedMarkerIDs = []
            return true
        }
        // Delete removes what's selected (the last trigger added, while keying in).
        if event.keyCode == 51 || event.keyCode == 117 {
            guard !locked, !selectedMarkerIDs.isEmpty else { return false }
            deleteSelected()
            return true
        }
        guard !locked, let chars = event.charactersIgnoringModifiers, let key = TriggerLane.normalizedKey(chars),
              let lane = lanes.first(where: { $0.key == key }) else { return false }
        if event.isARepeat { return true }
        // Where the music was when the key went down, not when the event got here.
        let late = transport.isPlaying ? max(0, min(0.25, CACurrentMediaTime() - event.timestamp)) : 0
        guard let marker = addTrigger(on: lane, at: transport.position() - late) else { return true }
        if control.settings.keysFire && !lane.muted { control.triggers.fire(lane: lane, marker: marker) }
        control.flash(marker.id, lane: lane.id)
        return true
    }

    /// Two fingers sideways (or a mouse wheel) pans; with ⌘ or ⌥ it zooms.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let x = trackX(event) else { return false }
        let width = Double(timelineTrackFrame.width)
        let precise = event.hasPreciseScrollingDeltas
        let dx = Double(event.scrollingDeltaX) * (precise ? 1 : 10)
        let dy = Double(event.scrollingDeltaY) * (precise ? 1 : 10)
        var w = timelineWindow
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            w.zoom(by: exp(dy * 0.01), around: w.time(atX: x, width: width))
        } else {
            // Up and down scrolls the lanes when there are more than fit; sideways pans.
            if timelineScrolls && abs(dy) > abs(dx) { return false }
            guard w.isZoomed else { return false }
            let delta = abs(dx) >= abs(dy) ? dx : dy
            w.pan(by: -delta / max(width, 1) * w.span)
        }
        if w != timelineWindow { timelineWindow = w }
        return true
    }

    /// Pinch to zoom, around the pointer.
    private func handleMagnify(_ event: NSEvent) -> Bool {
        guard let x = trackX(event) else { return false }
        var w = timelineWindow
        w.zoom(by: 1 + Double(event.magnification), around: w.time(atX: x, width: Double(timelineTrackFrame.width)))
        timelineWindow = w
        return true
    }

    /// The pointer's distance from the left of the tracks, when it's over the timeline.
    private func trackX(_ event: NSEvent) -> Double? {
        guard let content = event.window?.contentView, timelineTrackFrame.width > 0 else { return nil }
        let p = event.locationInWindow
        let y = content.bounds.height - p.y
        let frame = timelineTrackFrame
        guard y >= frame.minY - 40, y <= frame.maxY + 20, p.x >= frame.minX - 200, p.x <= frame.maxX + 20 else { return nil }
        return min(Double(frame.width), max(0, Double(p.x - frame.minX)))
    }

    // MARK: Selection and marker undo

    var selectedMarkers: [Marker] { currentSong?.markers.filter { selectedMarkerIDs.contains($0.id) } ?? [] }

    /// Shift-click and ⌘-click add or remove one from the selection.
    func toggleSelection(_ marker: Marker) {
        if selectedMarkerIDs.contains(marker.id) { selectedMarkerIDs.remove(marker.id) } else { selectedMarkerIDs.insert(marker.id) }
    }

    func selectAllMarkers() {
        selectedMarkerIDs = Set(currentSong?.markers.map(\.id) ?? [])
    }

    func deleteSelected() {
        guard let song = currentSong, !locked else { return }
        let gone = song.markers.filter { selectedMarkerIDs.contains($0.id) }
        guard !gone.isEmpty else { return }
        rememberMarkers(of: song)
        withAnimation(.vivid(0.35)) {
            edit { show in
                guard let i = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
                show.songs[i].markers.removeAll { selectedMarkerIDs.contains($0.id) }
            }
        }
        selectedMarkerIDs = []
        let triggers = gone.filter { $0.laneID != nil }.count, markers = gone.count - triggers
        var parts: [String] = []
        if triggers > 0 { parts.append("\(triggers) trigger\(triggers == 1 ? "" : "s")") }
        if markers > 0 { parts.append("\(markers) marker\(markers == 1 ? "" : "s")") }
        post("Deleted \(parts.joined(separator: " and ")).", markerUndo: true)
    }

    /// Moves every selected marker by the same number of frames, keeping their spacing.
    func shiftSelected(frames: Int) {
        guard let song = currentSong, !locked, frames != 0, !selectedMarkerIDs.isEmpty else { return }
        rememberMarkers(of: song)
        let len = playLength(of: song)
        let maxFrames: Int? = len > 0 ? Int(len * song.rate.framesPerSecond) : nil
        edit { show in
            guard let i = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
            for m in show.songs[i].markers.indices where selectedMarkerIDs.contains(show.songs[i].markers[m].id) {
                var f = show.songs[i].markers[m].time.frames(since: song.start) + frames
                f = max(0, maxFrames.map { min($0, f) } ?? f)
                show.songs[i].markers[m].time = song.start.adding(frames: f)
            }
            show.songs[i].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
        }
    }

    func nudgeSelected(frames: Int) { shiftSelected(frames: frames) }

    /// Drags of a selected marker move the whole selection.
    func moveSelected(by seconds: Double, dragging marker: Marker? = nil) {
        guard let song = currentSong else { return }
        let fps = song.rate.framesPerSecond
        var frames = Int((seconds * fps).rounded())
        if snapToGrid, let grid = song.beatGrid, let marker {
            let from = marker.time.frames(since: song.start)
            frames = grid.snapFrame(from + frames, fps: fps, to: snapDivision) - from
        }
        shiftSelected(frames: frames)
    }

    // MARK: Beat grid

    /// The song whose beat is being found right now.
    @Published private(set) var findingBeat: UUID?
    /// Markers dragged in the timeline land on the grid.
    @Published var snapToGrid = UserDefaults.standard.bool(forKey: "snapToGrid") {
        didSet { UserDefaults.standard.set(snapToGrid, forKey: "snapToGrid") }
    }
    @Published var snapDivision = BeatGrid.Division(rawValue: UserDefaults.standard.string(forKey: "snapDivision") ?? "") ?? .beat {
        didSet { UserDefaults.standard.set(snapDivision.rawValue, forKey: "snapDivision") }
    }

    /// Finds the tempo and the bars in the song's master, in the background. Nothing on the
    /// timeline moves: the grid is drawn, and says how well it fits.
    func findBeat(for song: Song) {
        guard !locked, findingBeat == nil else { return }
        guard let url = show?.url(forMediaPath: song.masterPath) else {
            post("\(song.title) needs a master to find the beat in. Or type the tempo in.")
            return
        }
        findingBeat = song.id
        let reader = self.reader, offset = song.fileOffset
        Task {
            let grid = await Task.detached(priority: .utility) { () -> BeatGrid? in
                guard let read = try? reader.readChannels(of: url), let first = read.channels.first, !first.isEmpty else { return nil }
                var mono = [Float](repeating: 0, count: first.count)
                for ch in read.channels {
                    for i in 0..<min(mono.count, ch.count) { mono[i] += ch[i] }
                }
                let k = 1 / Float(read.channels.count)
                for i in mono.indices { mono[i] *= k }
                return BeatDetector.detect(mono, sampleRate: read.sampleRate, fileOffset: offset)
            }.value
            self.findingBeat = nil
            guard let grid else {
                self.post("No steady beat found in \(song.title)'s master. Type the tempo in instead.")
                return
            }
            let before = self.show?.song(id: song.id)?.beatGrid
            self.setGrid(grid, for: song.id)
            self.postUndo(Self.describe(grid, title: song.title)) { [weak self] in self?.setGrid(before, for: song.id) }
        }
    }

    /// "Night Drive: 128 BPM, bar 1 on the song's start. Fits the whole song."
    static func describe(_ g: BeatGrid, title: String) -> String {
        var text = "\(title): \(g.tempoText)"
        let bar = (g.downbeat / g.barLength).rounded() * g.barLength
        text += abs(g.downbeat - bar) < 0.06 ? ", bar 1 on the song's start." : ", bar 1 from the kick."
        if let at = g.driftsAt {
            text += " Fits up to \(Self.clock(at)), then the music moves off it."
        } else if let fit = g.fit, fit < 0.8 {
            text += " Only fits about \(Int(fit * 100))% of the song: check it by ear."
        } else {
            text += " Fits the whole song."
        }
        if g.bpm > 160 || g.bpm < 80 { text += " If it feels twice as fast or slow, use ×2 or ÷2." }
        return text
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func setGrid(_ grid: BeatGrid?, for songID: UUID) {
        guard !locked else { return }
        edit { show in
            guard let i = show.songs.firstIndex(where: { $0.id == songID }) else { return }
            show.songs[i].beatGrid = grid
        }
    }

    /// Changes the current song's grid (tempo, bar 1, beats in a bar).
    func updateGrid(_ change: (inout BeatGrid) -> Void) {
        guard let song = currentSong, var grid = song.beatGrid else { return }
        change(&grid)
        setGrid(grid, for: song.id)
    }

    /// Types a tempo in: a new grid with bar 1 at the song's start, or the grid's new tempo.
    func setTempo(_ bpm: Double) {
        guard let song = currentSong, BeatGrid.tempoRange.contains(bpm) else { return }
        if var g = song.beatGrid {
            g.setTempo(bpm, keeping: g.downbeat)
            setGrid(g, for: song.id)
        } else {
            setGrid(BeatGrid(bpm: bpm), for: song.id)
        }
    }

    func barStartsAtPlayhead() { updateGrid { $0.barStarts(at: transport.position()) } }

    func removeGrid() {
        guard let song = currentSong, let before = song.beatGrid else { return }
        setGrid(nil, for: song.id)
        postUndo("Beat grid removed from \(song.title).") { [weak self] in self?.setGrid(before, for: song.id) }
    }

    /// Moves the selected markers and triggers onto the grid. ⌘Z puts them back.
    func tightenSelected() {
        guard let song = currentSong, !locked, !selectedMarkerIDs.isEmpty else { return }
        guard let grid = song.beatGrid else {
            post("\(song.title) has no beat grid yet. Find the beat first.")
            return
        }
        let fps = song.rate.framesPerSecond
        let len = playLength(of: song)
        let maxFrames: Int? = len > 0 ? Int(len * fps) : nil
        rememberMarkers(of: song)
        var moved = 0, most = 0
        edit { show in
            guard let i = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
            for m in show.songs[i].markers.indices where selectedMarkerIDs.contains(show.songs[i].markers[m].id) {
                let from = show.songs[i].markers[m].time.frames(since: song.start)
                var to = grid.snapFrame(from, fps: fps, to: snapDivision)
                to = max(0, maxFrames.map { min($0, to) } ?? to)
                if to != from {
                    moved += 1
                    most = max(most, abs(to - from))
                    show.songs[i].markers[m].time = song.start.adding(frames: to)
                }
            }
            show.songs[i].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
        }
        let n = selectedMarkerIDs.count
        if moved == 0 {
            post("Everything selected is already on the \(snapDivision.label.lowercased()).")
        } else {
            post("Moved \(moved) of \(n) onto the \(snapDivision.label.lowercased()), the furthest by \(most) frame\(most == 1 ? "" : "s").", markerUndo: true)
        }
    }

    private func rememberMarkers(of song: Song) {
        guard !locked, let current = show?.songs.first(where: { $0.id == song.id }) else { return }
        markerUndo.append((song.id, current.markers))
        if markerUndo.count > 100 { markerUndo.removeFirst() }
        markerRedo.removeAll()
    }

    var canUndoMarkers: Bool { !markerUndo.isEmpty }

    @discardableResult
    func undoMarkers() -> Bool {
        guard !locked, let step = markerUndo.popLast() else { return false }
        if let now = show?.songs.first(where: { $0.id == step.songID }) { markerRedo.append((step.songID, now.markers)) }
        restoreMarkers(step)
        return true
    }

    @discardableResult
    func redoMarkers() -> Bool {
        guard !locked, let step = markerRedo.popLast() else { return false }
        if let now = show?.songs.first(where: { $0.id == step.songID }) { markerUndo.append((step.songID, now.markers)) }
        restoreMarkers(step)
        return true
    }

    private func restoreMarkers(_ step: (songID: UUID, markers: [Marker])) {
        withAnimation(.vivid(0.3)) {
            edit { show in
                guard let i = show.songs.firstIndex(where: { $0.id == step.songID }) else { return }
                show.songs[i].markers = step.markers
            }
        }
        let ids = Set(step.markers.map(\.id))
        selectedMarkerIDs = selectedMarkerIDs.intersection(ids)
        if notice != nil && noticeOffersMarkerUndo { withAnimation(.vivid(0.3)) { notice = nil } }
    }

    func zoomTimeline(by factor: Double) {
        guard let song = currentSong else { return }
        var w = timelineWindow
        w.length = max(0.001, playLength(of: song))
        let p = transport.position()
        w.zoom(by: factor, around: w.contains(p) ? p : w.start + w.span / 2)
        withAnimation(.vivid(0.3)) { timelineWindow = w }
    }

    func zoomToFit() {
        var w = timelineWindow
        w.fit()
        withAnimation(.vivid(0.35)) { timelineWindow = w }
    }

    /// Moves the timeline so `seconds` is in view (after following the playhead, or dragging the overview).
    func showInTimeline(start seconds: Double) {
        var w = timelineWindow
        w.pan(by: seconds - w.start)
        if w != timelineWindow { timelineWindow = w }
    }

    // MARK: Remote control and following timecode

    /// A command from OSC or MIDI. Transport commands work in show mode; editing ones don't.
    func handle(_ command: RemoteCommand) {
        switch command {
        case .play: transport.play()
        case .stop: transport.pause()
        case .toggle: transport.toggle()
        case .next: next()
        case .previous: previous()
        case .top: transport.locate(transport.lowerBound)
        case .marker: addMarker(remote: true)
        case .song(let number):
            if let s = queue.first(where: { $0.number == number }) ?? (number <= queue.count ? queue[number - 1] : nil) { cue(s) }
        case .songTitle(let title):
            if let s = queue.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) { cue(s) }
        case .locate(let text):
            if let problem = goTo(timecode: text) { post(problem) }
        case .stopAfterEach(let on):
            stopAfterEach = on
        }
    }

    /// Carries out what following incoming timecode asks for.
    func follow(_ actions: [ChaseEngine.Action]) {
        var i = 0
        while i < actions.count {
            switch actions[i] {
            case let .cue(id, at):
                let playNext = i + 1 < actions.count && actions[i + 1] == .play
                if let song = show?.song(id: id) { cue(song, play: playNext, at: at) }
                if playNext { i += 1 }
            case .play: transport.play()
            case .stop: transport.pause()
            case .locate(let s): transport.locate(s)
            }
            i += 1
        }
    }

    // MARK: Fixing findings

    func fixLabel(_ fix: IssueFix, for issue: ShowIssue) -> String {
        let song = issue.songID.flatMap { show?.song(id: $0) }
        switch fix {
        case .useFileStart(let tc): return "Use the file's timecode (\(tc))"
        case .alignToSheet(let offset):
            return "Start where the file reads \(song?.start.description ?? "the sheet's start") (\(String(format: "%.2f", offset)) s in)"
        case .useFileRate(let rate): return "Use \(rate.displayName), like the file"
        case .chooseMaster: return song?.masterPath == nil ? "Choose master…" : "Choose another master…"
        case .chooseTimecode: return song?.timecodePath == nil ? "Choose timecode file…" : "Choose another timecode file…"
        case .locate: return "Go there"
        case .audioOutput: return "Audio output…"
        }
    }

    func fixHelp(_ fix: IssueFix, for issue: ShowIssue) -> String {
        let name = issue.songID.flatMap { show?.song(id: $0)?.title } ?? "The song"
        switch fix {
        case .useFileStart(let tc):
            return "Changes \(name)'s start on the show to \(tc), what its timecode file reads. The audio and the timecode going out don't change; the clock, markers and checks follow the file."
        case .alignToSheet(let offset):
            return "Keeps the sheet's start and begins \(name) \(String(format: "%.2f", offset)) s into its files, where the timecode file reads it. Anything before that plays as pre-roll."
        case .useFileRate(let rate):
            return "Sets \(name) to \(rate.displayName), the rate its timecode file runs at."
        case .chooseMaster, .chooseTimecode: return "Pick the file for \(name)."
        case .locate: return "Cues \(name) and puts the playhead where the problem is, so you can listen."
        case .audioOutput: return "Open the audio output settings."
        }
    }

    /// Carries out a fix the person clicked. Fixes that change the show are off in show mode
    /// and can be undone (Edit › Undo Fix).
    func perform(_ fix: IssueFix, for issue: ShowIssue) {
        if case .audioOutput = fix {
            issuesShown = false
            outputShown = true
            return
        }
        guard let songID = issue.songID, let song = show?.song(id: songID) else { return }
        switch fix {
        case .chooseMaster: choose(.master, for: song)
        case .chooseTimecode: choose(.timecode, for: song)
        case .locate(let seconds):
            issuesShown = false
            if currentSong?.id != songID { cue(song, play: false) }
            DispatchQueue.main.async { self.transport.locate(seconds) }
        case .audioOutput: break
        case .useFileStart, .alignToSheet, .useFileRate:
            guard !locked else { post("Show mode is on. Turn it off (⇧⌘L) to change the show."); return }
            let label = fixLabel(fix, for: issue)
            DispatchQueue.main.async { [weak self] in
                guard let self, var show = self.show else { return }
                guard let before = ShowFixer.apply(fix, songID: songID, to: &show) else { return }
                self.show = show
                self.save()
                self.lastFix = FixUndo(song: before, label: label)
                self.filesChanged(before)
                self.post("\(song.title): \(label.prefix(1).lowercased() + label.dropFirst()). Undo with ⌥⌘Z.", undo: true)
            }
        }
    }

    func undoFix() {
        guard let u = lastFix, var show, !locked else { return }
        ShowFixer.undo(u.song, in: &show)
        self.show = show
        save()
        lastFix = nil
        filesChanged(u.song)
        post("Undone: \(u.song.title) is back as it was.")
    }

    // MARK: Adding audio after import

    /// Matches files (or whole folders) to the songs still missing a master or timecode file.
    func addAudio(_ urls: [URL]) {
        guard !locked, var show else { return }
        let result = ShowImporter.attach(ShowImporter.expand(urls), to: &show, reader: reader)
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
            filesChanged(song)
            if transport.isPlaying && currentSong?.id == song.id { return }
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
    private func filesChanged(_ changed: Song? = nil) {
        guard let show else { return }
        transport.invalidateCache()
        keepSetReady()
        waveforms = [:]
        if let song = currentSong {
            if transport.isPlaying {
                transport.update(song, in: show)
                if changed == nil || changed?.id == song.id {
                    post("\(song.title) keeps playing what it had. The new file is used the next time it's cued.")
                }
            } else {
                cue(song, play: false)
            }
        }
        recheck()
    }

    /// Drop of a single file on a song: listen for LTC to decide if it's the timecode file.
    func dropFile(_ url: URL, on song: Song) {
        let role = ShowImporter.detectRole(url, reader: reader)
        assign(url, role: role == .timecode ? .timecode : .master, to: song)
    }

    func post(_ text: String, undo: Bool = false, markerUndo: Bool = false) {
        noticeOffersUndo = undo
        noticeOffersMarkerUndo = markerUndo
        noticeUndoAction = nil
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

    /// Where an imported show is kept: ~/Documents/Vivid Playback, under a name no other show has.
    private func newPackage(for show: Show) -> URL {
        try? FileManager.default.createDirectory(at: Self.showsFolder, withIntermediateDirectories: true)
        return ShowLibrary.uniquePackageURL(named: show.name, in: Self.showsFolder)
    }

    private func prepared(_ report: ImportReport, artist: String?, name: String?) -> Show {
        var show = report.show
        if let artist {
            let a = artist.trimmingCharacters(in: .whitespaces)
            show.artist = a.isEmpty ? nil : a
        }
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { show.name = n }
        // Start on this Mac's interface; Caiden picks the timecode output once.
        if show.routing.deviceUID == nil { show.routing.deviceUID = AudioDevices.defaultOutput()?.uid }
        return show
    }

    /// Adds an imported show to the Albums page without opening it (playback carries on).
    func saveImported(_ report: ImportReport, artist: String? = nil, name: String? = nil) {
        let show = prepared(report, artist: artist, name: name)
        let package = newPackage(for: show)
        do {
            try ShowStore.save(show, to: package)
        } catch {
            importState = .failed("Couldn't save \(show.name): \(error.localizedDescription)")
            return
        }
        importState = .idle
        addAlbumShown = false
        refreshLibrary()
        go(.albums)
        let n = show.setlists.count
        post("Added \(show.name) to Albums\(n > 1 ? " (\(n) albums)" : "").")
    }

    /// Opens an imported show and saves it as a package in ~/Documents/Vivid Playback.
    func openImported(_ report: ImportReport, artist: String? = nil, name: String? = nil) {
        guard !transport.isPlaying || show == nil else {
            post("Stop playback before opening another show. You can add it to Albums now and open it later.")
            return
        }
        let show = prepared(report, artist: artist, name: name)
        load(show, package: newPackage(for: show), issues: report.issues)
        save()
        importState = .idle
        let fromAlbums = addAlbumShown || importReturn == .albums
        addAlbumShown = false
        importReturn = nil
        refreshLibrary()
        go(fromAlbums ? .albums : .library)
        if needsTimecodeOutput { outputShown = true }
    }

    func open(package: URL) {
        flushSave(wait: true)
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
            current.pruneDismissed(keeping: issues)
            for (i, song) in current.songs.enumerated() {
                guard let fresh = checked.song(id: song.id) else { continue }
                if song.length == nil { current.songs[i].length = fresh.length }
                // Measured every time: the audio decides how long the song plays.
                current.songs[i].audioLength = fresh.audioLength
                if song.timecodeFileChannel == nil { current.songs[i].timecodeFileChannel = fresh.timecodeFileChannel }
            }
            self.show = current
            self.save()
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
        keepSetReady()
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
        keepSetReady()
        transport.configure(routing: show.routing)
        if let first = queue.first { cue(first, play: false) }
        UserDefaults.standard.set(package.path, forKey: "lastShowPath")
        sort = .setlist
        refreshLibrary()
    }

    /// Saves after every change. A failure is said out loud, never swallowed.
    /// Saves after a change. Changes that come quickly (recording from the desk, dragging) are
    /// gathered and written once, half a second after the last, off the main thread, so the
    /// timeline never waits for the disk. Switching shows and quitting write at once.
    func save() {
        guard let show, let packageURL else { return }
        if let p = pendingSave, p.url.standardizedFileURL != packageURL.standardizedFileURL { writeSave(p, wait: true) }
        pendingSave = (show, packageURL)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushSave() }
        }
    }

    private var pendingSave: (show: Show, url: URL)?
    private var saveTimer: Timer?
    private let saveQueue = DispatchQueue(label: "vivid.save", qos: .utility)

    /// Writes any change still waiting. With `wait`, it's on disk before this returns.
    func flushSave(wait: Bool = false) {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let p = pendingSave else {
            if wait { saveQueue.sync {} }
            return
        }
        pendingSave = nil
        writeSave(p, wait: wait)
    }

    /// Forgets a change still waiting (the show's file went to the Trash).
    private func dropPendingSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        pendingSave = nil
    }

    private func writeSave(_ p: (show: Show, url: URL), wait: Bool) {
        let show = p.show, url = p.url
        if wait {
            let error = saveQueue.sync { Self.write(show, to: url) }
            saved(show, to: url, error: error)
        } else {
            saveQueue.async {
                let error = Self.write(show, to: url)
                Task { @MainActor [weak self] in self?.saved(show, to: url, error: error) }
            }
        }
    }

    nonisolated private static func write(_ show: Show, to url: URL) -> String? {
        do {
            try ShowStore.save(show, to: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func saved(_ show: Show, to url: URL, error: String?) {
        if let error {
            post("Couldn't save the show to \(url.path): \(error)")
            return
        }
        lastSaved = Date()
        if let i = library.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            library[i] = ShowLibrary.Entry(url: url, show: show)
        }
    }

    /// File › Save: the show is already saved; this saves once more and says where.
    func saveNow() {
        guard let packageURL else { return }
        save()
        flushSave(wait: true)
        post("Saved to \(packageURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Every change saves itself.")
    }

    /// A copy of the show file somewhere else (a backup, a USB stick). The audio stays where it is;
    /// on another Mac, use Relink Media Folder to point the copy at the audio.
    func saveCopy() {
        guard let show else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(show.name).\(ShowStore.fileExtension)"
        panel.prompt = "Save Copy"
        panel.message = "Saves a copy of the show file. The audio files aren't copied."
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != ShowStore.fileExtension { url.appendPathExtension(ShowStore.fileExtension) }
        do {
            try ShowStore.save(show, to: url)
            post("Copy saved to \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
        } catch {
            post("Couldn't save the copy: \(error.localizedDescription)")
        }
    }

    func revealShowFile() {
        guard let packageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([packageURL])
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
        importReturn = show == nil ? nil : (screen == .firstRun ? .library : screen)
        go(.firstRun)
    }

    private func runDemo(_ name: String) {
        var demoZoom = false
        var demoAddAlbum = false
        var demoLabels = false
        var demoRecord = false
        let target: Screen
        switch name {
        case "library": target = .library
        case "timeline": target = .timeline
        case "zoomed": target = .timeline; demoZoom = true
        case "clock": target = .clock
        case "connections": target = .connections
        case "consoles": target = .connections; connectionsAnchor = "consoles"
        case "albums": target = .albums
        case "player": target = .player
        case "add-album": target = .albums; demoAddAlbum = true
        case "labels": target = .timeline; demoLabels = true
        case "record": target = .timeline; demoRecord = true
        default: return
        }
        if target == .connections {
            control.settings.mtcOut = true
            control.settings.artNetOut = true
            control.settings.oscIn = true
        }
        let zoomIn = demoZoom
        let addAlbumSheet = demoAddAlbum
        let labelsSheet = demoLabels
        let recordArmed = demoRecord
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
            if target == .timeline, show.songs.count > 2 {
                let song = show.songs[2]
                let fps = song.rate.framesPerSecond
                let main = TriggerLane(name: "Main cues", page: 1, executor: 201, color: 0, key: "1")
                let strobes = TriggerLane(name: "Strobes", page: 1, executor: 202, action: .fader, color: 2, key: "2")
                let video = TriggerLane(name: "Video", page: 2, executor: 101, color: 4, key: "3")
                show.songs[2].triggerLanes = [main, strobes, video]
                func at(_ t: Double, _ lane: TriggerLane, _ label: String, _ value: Double? = nil) -> Marker {
                    Marker(time: song.start.adding(frames: Int(t * fps)), label: label, laneID: lane.id, value: value)
                }
                show.songs[2].markers += [
                    at(0.4, main, "Go+ 1"), at(5, main, "Go+ 2"), at(11, main, "Go+ 3"), at(17, main, "Go+ 4"),
                    at(10.6, strobes, "Full", 100), at(12.4, strobes, "Out", 0),
                    at(2, video, "Go+ 1"), at(14, video, "Go+ 2"),
                ]
                show.songs[2].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
                if control.settings.consoles.isEmpty {
                    control.settings.consoles = [ConsoleTarget(name: "MA3 FOH", host: "10.0.0.20"),
                                                 ConsoleTarget(name: "MA3 Backup", host: "10.0.0.21", enabled: false)]
                }
            }
            if target == .connections, control.settings.consoles.isEmpty {
                control.settings.consoles = [ConsoleTarget(name: "MA3 FOH", host: "10.0.0.20"),
                                             ConsoleTarget(name: "MA3 Backup", host: "10.0.0.21", enabled: false)]
            }
            load(show, package: folder.appendingPathComponent("Example.vividshow"), issues: report.issues)
            if let third = queue.dropFirst(2).first { cue(third, play: false) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            transport.locate(9.4)
            if zoomIn, let song = currentSong {
                var w = TimelineWindow(length: playLength(of: song))
                w.setZoom(3, around: 9.4)
                timelineWindow = w
                // A box selection across the lanes, between 10 and 18 seconds.
                let fps = song.rate.framesPerSecond
                selectedMarkerIDs = Set(song.markers.filter {
                    let t = Double($0.time.frames(since: song.start)) / fps
                    return t >= 10 && t <= 15 && $0.laneID != nil
                }.map(\.id))
            }
            screen = target
            if !zoomIn { transport.play() }
            if recordArmed {
                toggleDeskRecording()
                lastDeskGo = ("OSC GO 1.201 cue 3 → Main cues at 03:00:11:00", Date())
            }
            if labelsSheet {
                try? await Task.sleep(nanoseconds: 400_000_000)
                labelsShown = true
            }
            if addAlbumSheet {
                try? await Task.sleep(nanoseconds: 400_000_000)
                addAlbum()
            }
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
