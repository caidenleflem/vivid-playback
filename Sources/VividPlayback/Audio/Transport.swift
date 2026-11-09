import SwiftUI
import QuartzCore
import PlaybackCore

/// The playhead. With an audio output running it follows the audio clock (the sample the
/// interface is playing); without one it runs a plain clock so the show can still be rehearsed.
/// Positions are seconds from the song's start timecode; negative is pre-roll.
@MainActor
final class Transport: ObservableObject {
    enum OutputStatus: Equatable {
        /// No audio: why, in plain words.
        case clockOnly(String)
        case playing(device: String)
        /// The interface went away mid-show.
        case lost(String)
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var status: OutputStatus = .clockOnly("Choose an audio output")
    @Published private(set) var isLoading = false
    @Published private(set) var timecodeGenerated = false
    @Published private(set) var timecodeRouted = false
    /// Seconds from the song start; nil when not looping.
    @Published private(set) var loop: ClosedRange<Double>?

    let audio = AudioOutput()
    private(set) var song: Song?
    private var show: Show?
    private var buffers: PlaybackBuffers?
    private var cache: [UUID: PlaybackBuffers] = [:]
    private var anchorPosition: Double = 0
    private var anchorTime: CFTimeInterval = CACurrentMediaTime()
    private var timer: Timer?
    private var loadToken = UUID()
    var onSongEnd: (() -> Void)?

    var length: Double { song?.length ?? buffers.map { $0.duration - (song?.fileOffset ?? 0) } ?? 0 }
    var lowerBound: Double { -(song?.fileOffset ?? 0) }
    var usesAudio: Bool { buffers != nil && audio.isRunning }
    var deviceName: String? { audio.device?.name }

    // MARK: Output

    /// Starts (or restarts) the interface the show is routed to. Never starts playback.
    func configure(routing: OutputRouting) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        let keep = position()
        let device = routing.deviceUID.flatMap(AudioDevices.device(uid:)) ?? AudioDevices.defaultOutput()
        guard let device else {
            audio.stop()
            status = .clockOnly("No audio output found")
            return
        }
        let rateChanged = audio.sampleRate != device.sampleRate
        do {
            if audio.device?.uid != device.uid || !audio.isRunning { try audio.start(on: device) }
            if routing.deviceUID != nil && routing.deviceUID != device.uid {
                status = .lost("The show's interface isn't connected. Playing on \(device.name).")
            } else {
                status = .playing(device: device.name)
            }
        } catch {
            status = .clockOnly(String(describing: error))
        }
        applyRouting(routing)
        if rateChanged { cache = [:] }
        if let song, let show, rateChanged || buffers == nil || buffers?.sampleRate != audio.sampleRate {
            reload(song, in: show, at: keep, play: false)
        } else {
            locate(keep)
        }
    }

    func applyRouting(_ routing: OutputRouting) {
        audio.state.map = OutputMap(routing: routing, channelCount: audio.channelCount)
        audio.state.masterGain = Mixer.gain(dB: routing.masterGainDB)
        audio.state.timecodeGain = Mixer.gain(dB: routing.timecodeGainDB)
        timecodeRouted = audio.state.map.timecode != nil
    }

    /// Called when interfaces are plugged in or out.
    func devicesChanged(routing: OutputRouting) {
        let present = AudioDevices.all()
        if let current = audio.device, !present.contains(where: { $0.uid == current.uid }) {
            pause()
            audio.stop()
            status = .lost("\(current.name) disconnected. Playback stopped.")
            return
        }
        if case .lost = status, let uid = routing.deviceUID, present.contains(where: { $0.uid == uid }) {
            configure(routing: routing)
        } else if !audio.isRunning {
            configure(routing: routing)
        }
    }

    // MARK: Songs

    func load(_ song: Song, in show: Show, play: Bool? = nil) {
        let resume = play ?? isPlaying
        pause()
        loop = nil
        audio.state.loop = nil
        reload(song, in: show, at: -song.fileOffset, play: resume)
    }

    /// Keeps the song data current (markers, lengths) without touching playback.
    func update(_ song: Song, in show: Show) {
        self.show = show
        if self.song?.id == song.id { self.song = song }
    }

    private func reload(_ song: Song, in show: Show, at position: Double, play: Bool) {
        self.song = song
        self.show = show
        let token = UUID()
        loadToken = token
        guard audio.isRunning else {
            buffers = nil
            audio.state.buffers = nil
            timecodeGenerated = song.hasTimecode && song.timecodePath == nil
            locate(position)
            if play { self.play() }
            return
        }
        if let cached = cache[song.id], cached.sampleRate == audio.sampleRate {
            install(cached, at: position, play: play)
            return
        }
        isLoading = true
        let rate = audio.sampleRate
        Task {
            let b = await Task.detached(priority: .userInitiated) { SongLoader.buffers(for: song, in: show, sampleRate: rate) }.value
            guard self.loadToken == token else { return }
            self.isLoading = false
            self.cache[song.id] = b
            self.install(b, at: position, play: play)
        }
    }

    private func install(_ b: PlaybackBuffers, at position: Double, play: Bool) {
        let old = buffers
        audio.state.playing = false
        audio.state.buffers = b
        buffers = b
        timecodeGenerated = b.timecodeGenerated
        locate(position)
        if play { self.play() }
        // Let the audio thread finish any block that still uses the old song before it's freed.
        if let old { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = old } }
    }

    /// Loads the next song in the background so auto-advance is instant.
    func preload(_ song: Song?, in show: Show) {
        guard let song, audio.isRunning, cache[song.id] == nil else { return }
        let rate = audio.sampleRate
        Task {
            let b = await Task.detached(priority: .utility) { SongLoader.buffers(for: song, in: show, sampleRate: rate) }.value
            if self.audio.sampleRate == rate { self.cache[song.id] = b }
            // Keep memory in check: the current song, the next one, and nothing else.
            let keep: Set<UUID> = [self.song?.id, song.id].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
            self.cache = self.cache.filter { keep.contains($0.key) }
        }
    }

    func invalidateCache() { cache = [:] }

    // MARK: Playhead

    func position(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard usesAudio, let song else {
            return isPlaying ? anchorPosition + (time - anchorTime) : anchorPosition
        }
        let s = audio.state
        if s.pendingLocate >= 0 { return Double(s.pendingLocate) / audio.sampleRate - song.fileOffset }
        var frames = Double(s.renderedPosition)
        if s.playing {
            // Between audio blocks, count on in real time; then allow for the interface's latency.
            frames += min(0.1, max(0, time - s.renderedAt)) * audio.sampleRate
            frames -= audio.latency * audio.sampleRate
        }
        var seconds = frames / audio.sampleRate - song.fileOffset
        if let loop, s.loop != nil, seconds > loop.upperBound { seconds = loop.lowerBound + (seconds - loop.upperBound) }
        return seconds
    }

    func play() {
        guard !isPlaying, song != nil else { return }
        if case .lost = status, !audio.isRunning { return }  // show-safe: no silent clock after a lost interface
        if usesAudio {
            audio.state.playing = true
        } else {
            anchorTime = CACurrentMediaTime()
        }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEnd() }
        }
    }

    func pause() {
        guard isPlaying else { return }
        if usesAudio {
            audio.state.playing = false
        } else {
            anchorPosition = position()
        }
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func toggle() { isPlaying ? pause() : play() }

    func locate(_ seconds: Double) {
        let clamped = max(lowerBound, min(seconds, max(length, lowerBound)))
        if usesAudio, let song {
            let frame = max(0, Int(((clamped + song.fileOffset) * audio.sampleRate).rounded()))
            audio.state.pendingLocate = frame
            audio.state.renderedPosition = frame
            audio.state.renderedAt = CACurrentMediaTime()
        }
        anchorPosition = clamped
        anchorTime = CACurrentMediaTime()
        objectWillChange.send()
    }

    /// Loops between two points of the song (seconds from its start); nil stops looping.
    func setLoop(_ range: ClosedRange<Double>?) {
        loop = range
        guard let range, let song, usesAudio else { audio.state.loop = nil; return }
        let toFrame = { (s: Double) in Int(((s + song.fileOffset) * self.audio.sampleRate).rounded()) }
        audio.state.loop = LoopRegion(start: toFrame(range.lowerBound), end: toFrame(range.upperBound))
    }

    private func checkEnd() {
        guard isPlaying else { return }
        let p = position()
        if loop != nil && !usesAudio, let loop, p >= loop.upperBound {
            locate(loop.lowerBound)
            return
        }
        if loop == nil, length > 0, p >= length { onSongEnd?() }
    }
}
