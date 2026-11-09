import SwiftUI
import AppKit
import AVFoundation
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

/// The playhead. For now it's a clock: it runs the timecode display, the progress and the
/// setlist, without sound. The audio engine (master and LTC out, sample-locked) replaces the
/// clock source in the next build; everything that reads `position(at:)` stays the same.
@MainActor
final class Transport: ObservableObject {
    @Published private(set) var isPlaying = false
    /// Seconds from the song's start timecode when the clock was last anchored.
    @Published private(set) var anchorPosition: Double = 0
    private var anchorTime: CFTimeInterval = CACurrentMediaTime()
    private var timer: Timer?
    var length: Double = 0
    var onSongEnd: (() -> Void)?

    func position(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
        isPlaying ? anchorPosition + (time - anchorTime) : anchorPosition
    }

    func play() {
        guard !isPlaying else { return }
        anchorTime = CACurrentMediaTime()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEnd() }
        }
    }

    func pause() {
        guard isPlaying else { return }
        anchorPosition = position()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func toggle() { isPlaying ? pause() : play() }

    func locate(_ seconds: Double) {
        anchorPosition = max(0, min(seconds, length))
        anchorTime = CACurrentMediaTime()
    }

    func load(length: Double) {
        self.length = length
        locate(0)
    }

    private func checkEnd() {
        if isPlaying && length > 0 && position() >= length { onSongEnd?() }
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
    @Published var selectedSetlistID: UUID?

    let transport = Transport()
    private let reader = AVAudioFileReader()

    init() {
        transport.onSongEnd = { [weak self] in self?.advanceAfterSongEnd() }
        // `--demo library|timeline|clock` opens the example show on that screen, rolling.
        // Used by the build to screenshot each screen.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--demo") {
            if i + 1 < args.count { runDemo(args[i + 1]) }
            return
        }
        reopenLastShow()
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
            load(report.show, package: folder.appendingPathComponent("Example.vividshow"), issues: report.issues)
            if let third = queue.dropFirst(2).first ?? queue.first { cue(third) }
            transport.locate(9.4)
            if target == .timeline, var show = self.show, let song = currentSong,
               let index = show.songs.firstIndex(where: { $0.id == song.id }) {
                show.songs[index].markers = [(0.4, "Hit 1"), (5, "Verse 1"), (11, "Chorus · big look"), (17, "Bridge · blackout")].map {
                    Marker(time: song.start.adding(frames: Int($0.0 * song.rate.framesPerSecond)), label: $0.1)
                }
                self.show = show
            }
            screen = target
            transport.play()
        }
    }

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

    func cue(_ song: Song) {
        currentSongID = song.id
        transport.load(length: song.length ?? 0)
        loadWaveform(for: song)
    }

    func next() {
        let q = queue
        guard let cur = currentSong, let i = q.firstIndex(where: { $0.id == cur.id }), i + 1 < q.count else { return }
        cue(q[i + 1])
    }

    func previous() {
        let q = queue
        guard let cur = currentSong, let i = q.firstIndex(where: { $0.id == cur.id }) else { return }
        // Like a music player: back to the top first, then the song before.
        if transport.position() > 3 || i == 0 { transport.locate(0) } else { cue(q[i - 1]) }
    }

    private func advanceAfterSongEnd() {
        if nextSong != nil {
            let wasPlaying = transport.isPlaying
            next()
            if wasPlaying { transport.play() }
        } else {
            transport.pause()
            transport.locate(transport.length)
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

    // MARK: Markers

    func addMarker() {
        guard screen == .timeline, var show, let song = currentSong, let i = show.songs.firstIndex(where: { $0.id == song.id }) else { return }
        let tc = timecode(for: song, at: transport.position())
        let n = show.songs[i].markers.count + 1
        withAnimation(.vivid(0.45)) {
            show.songs[i].markers.append(Marker(time: tc, label: "Marker \(n)"))
            show.songs[i].markers.sort { $0.time.frames(since: song.start) < $1.time.frames(since: song.start) }
            self.show = show
        }
        save()
    }

    // MARK: Import, open, save

    func chooseFolder() {
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
        importState = .running(.scanning)
        let reader = self.reader
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try ShowImporter(reader: reader).importFolder(folder, progress: { step in
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
        load(report.show, package: package, issues: report.issues)
        save()
        importState = .idle
        go(.library)
    }

    func open(package: URL) {
        do {
            let show = try ShowStore.load(from: package)
            load(show, package: package, issues: [])
            go(.library)
            // Re-check the files in the background: they may have changed since the last session.
            let reader = self.reader
            Task {
                let (checked, issues) = await Task.detached { () -> (Show, [ShowIssue]) in
                    var copy = show
                    let result = ShowImporter(reader: reader).check(&copy)
                    return (copy, result.issues)
                }.value
                self.issues = issues
                guard var current = self.show else { return }
                for (i, song) in current.songs.enumerated() where song.length == nil {
                    current.songs[i].length = checked.song(id: song.id)?.length
                }
                self.show = current
            }
        } catch {
            importState = .failed("Couldn't open \(package.lastPathComponent): \(error.localizedDescription)")
            screen = .firstRun
        }
    }

    func openShowPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Open Show"
        if panel.runModal() == .OK, let url = panel.url { open(package: url) }
    }

    private func load(_ show: Show, package: URL, issues: [ShowIssue]) {
        self.show = show
        self.packageURL = package
        self.issues = issues
        self.selectedSetlistID = show.setlists.first?.id
        waveforms = [:]
        if let first = queue.first { cue(first) }
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
        transport.pause()
        importState = .idle
        go(.firstRun)
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
