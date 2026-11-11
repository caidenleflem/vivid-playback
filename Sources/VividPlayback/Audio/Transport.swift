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
    /// Where the current song's timecode comes from.
    @Published private(set) var source: TimecodeSource = .none
    /// The timecode file has readable LTC in it (only meaningful for `.file`).
    @Published private(set) var trackFound = false
    @Published private(set) var masterProblem: String?
    @Published private(set) var timecodeRouted = false
    /// Seconds from the song start; nil when not looping.
    @Published private(set) var loop: ClosedRange<Double>?

    let audio = AudioOutput()
    lazy var clock = OutputClock(state: audio.state)
    /// Test timecode is going out (line check).
    @Published private(set) var testing = false
    /// How much of the set is loaded and ready to switch to instantly (of how many that fit).
    @Published private(set) var readyCount = 0
    @Published private(set) var readyTotal = 0
    /// Songs the Mac doesn't have the memory to keep ready (they load when cued).
    @Published private(set) var notKept = 0
    private(set) var song: Song?
    private var show: Show?
    private var buffers: PlaybackBuffers?

    /// A song read into memory, ready to play, and the file state it was read from.
    struct Loaded {
        let buffers: PlaybackBuffers
        let masterProblem: String?
        let key: Song.AudioKey
    }
    private var cache: [UUID: Loaded] = [:]
    private var inFlight: [UUID: Task<Loaded, Never>] = [:]
    /// The songs to keep ready, most needed first.
    private var wanted: [Song] = []
    private var warming: Task<Void, Never>?
    private var warmAgain = false

    /// The song armed to follow the current one without a gap.
    private struct Armed {
        var song: Song
        let loaded: Loaded
        let after: PlaybackBuffers
        let serial: Int
    }
    private var armed: Armed?
    /// Recent arms by serial, so an advance can always be matched to its song, even one that
    /// raced a change of arm. Cleared on a cut: an advance from before it is stale.
    private var arms: [Int: Armed] = [:]
    private var armSerial = 0
    private var seenAdvances = 0
    private var armCheck = 0

    private var anchorPosition: Double = 0
    private var anchorTime: CFTimeInterval = CACurrentMediaTime()
    private var timer: Timer?
    private var loadToken = UUID()
    /// Bumped whenever files change, so a load that started before can't cache old audio.
    private var generation = 0
    var onSongEnd: (() -> Void)?
    /// The song that should follow the current one without a gap (nil: stop at the end).
    var wantedNext: (() -> Song?)?
    /// The audio ran on into the next song: the app catches up (the song is already playing).
    var onAdvance: ((Song) -> Void)?

    /// How long the song plays: the loaded audio when it's this song's (so a song runs to the end
    /// of its files, whatever the sheet said), else the measured or sheet length.
    var length: Double {
        if let b = buffers, buffersSongID == song?.id { return max(0, b.duration - (song?.fileOffset ?? 0)) }
        return song?.playLength ?? 0
    }
    /// Which song `buffers` holds (it lags behind `song` while the next one loads).
    private var buffersSongID: UUID?
    var lowerBound: Double { -(song?.fileOffset ?? 0) }
    var usesAudio: Bool { buffers != nil && audio.isRunning }
    var deviceName: String? { interfaces.isEmpty ? audio.device?.name : interfaces.map(\.name).joined(separator: " + ") }

    // MARK: Output

    /// The interfaces playing, in output order: the master's, then the timecode interface when
    /// it's a different one.
    private(set) var interfaces: [AudioDevice] = []
    /// A routing to apply once playback stops (an interface came back mid-song).
    private var pendingRouting: OutputRouting?

    /// Starts (or restarts) the interface the show is routed to. Never starts playback.
    /// With timecode on a different interface, both are joined into one device so the master and
    /// the timecode still come from one frame counter, the master's interface being the clock.
    func configure(routing: OutputRouting) {
        pendingRouting = nil
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        let keep = position()
        let master = routing.deviceUID.flatMap(AudioDevices.device(uid:)) ?? AudioDevices.defaultOutput()
        guard let master else {
            audio.stop()
            interfaces = []
            status = .clockOnly("No audio output found")
            return
        }
        var target = master
        var playing = [master]
        var timecodeProblem: String?
        if routing.splitsInterfaces, let uid = routing.timecodeDeviceUID, uid != master.uid {
            if let tc = AudioDevices.device(uid: uid) {
                if let joined = AudioDevices.joined(master: master, timecode: tc) {
                    target = joined
                    playing = [master, tc]
                } else {
                    timecodeProblem = "Couldn't play \(master.name) and \(tc.name) together, so no timecode is going out. Check both run at the same sample rate in Audio MIDI Setup."
                }
            } else {
                timecodeProblem = "The timecode interface isn't connected, so no timecode is going out. The master plays on \(master.name)."
            }
        }
        AudioDevices.removeJoined(keeping: target.uid)
        let rateChanged = audio.sampleRate != target.sampleRate
        do {
            if audio.device?.uid != target.uid || !audio.isRunning { try audio.start(on: target) }
            if routing.deviceUID != nil && routing.deviceUID != master.uid {
                status = .lost("The show's interface isn't connected. Playing on \(master.name).")
            } else if let timecodeProblem {
                status = .lost(timecodeProblem)
            } else {
                status = .playing(device: playing.map(\.name).joined(separator: " + "))
            }
        } catch {
            status = .clockOnly(String(describing: error))
        }
        interfaces = playing
        applyRouting(routing)
        if rateChanged { dropCache() }
        if let song, let show, rateChanged || buffers == nil || buffers?.sampleRate != audio.sampleRate {
            switchTo(song, in: show, at: keep, play: false)
        } else {
            locate(keep)
        }
        scheduleWarm()
    }

    func applyRouting(_ routing: OutputRouting) {
        let slots = interfaces.isEmpty
            ? [OutputSlot(uid: routing.deviceUID ?? "", outputs: audio.channelCount)]
            : interfaces.map { OutputSlot(uid: $0.uid, outputs: $0.outputChannels) }
        var map = OutputMap(routing: routing, slots: slots)
        // Never address an output the running device doesn't have.
        map.channelCount = audio.channelCount
        if let t = map.timecode, t >= audio.channelCount { map.timecode = nil }
        if let l = map.masterLeft, l >= audio.channelCount { map.masterLeft = nil }
        if let r = map.masterRight, r >= audio.channelCount { map.masterRight = nil }
        audio.state.map = map
        audio.state.masterGain = Mixer.gain(dB: routing.masterGainDB)
        audio.state.timecodeGain = Mixer.gain(dB: routing.timecodeGainDB)
        timecodeRouted = audio.state.map.timecode != nil
    }

    /// Where the master's left side and the timecode come out of the running device (0-based),
    /// for the meters.
    var masterOutput: Int? { audio.isRunning ? audio.state.map.masterLeft : nil }
    var masterRightOutput: Int? { audio.isRunning ? audio.state.map.masterRight : nil }
    var timecodeOutput: Int? { audio.isRunning ? audio.state.map.timecode : nil }
    /// The interface timecode goes out on (the second one when they're split).
    var timecodeInterface: AudioDevice? { interfaces.count > 1 ? interfaces[1] : interfaces.first }

    /// Called when interfaces are plugged in or out.
    func devicesChanged(routing: OutputRouting) {
        let present = AudioDevices.presentUIDs()
        if audio.isRunning, let gone = interfaces.first(where: { !present.contains($0.uid) }) {
            pause()
            audio.stop()
            status = .lost("\(gone.name) disconnected. Playback stopped.")
            return
        }
        let wanted = [routing.deviceUID, routing.splitsInterfaces ? routing.timecodeDeviceUID : nil].compactMap { $0 }
        let missingBefore = wanted.contains { uid in !interfaces.contains { $0.uid == uid } }
        guard !audio.isRunning || (missingBefore && wanted.allSatisfy(present.contains)) else { return }
        // Never restart the audio mid-song: an interface that comes back is used once it stops.
        if isPlaying {
            pendingRouting = routing
            return
        }
        configure(routing: routing)
    }

    // MARK: Songs

    /// Cues a song. When it's in memory (the whole set normally is) the switch is instant: the
    /// new song starts on the next audio block, and if one was playing it fades out underneath
    /// in a few milliseconds instead of clicking.
    func load(_ song: Song, in show: Show, play: Bool? = nil, at position: Double? = nil) {
        syncAdvance()
        let resume = play ?? isPlaying
        if testing { stopTest() }
        loop = nil
        switchTo(song, in: show, at: position ?? -song.fileOffset, play: resume)
    }

    /// Keeps the song data current (markers, lengths) without touching playback.
    func update(_ song: Song, in show: Show) {
        self.show = show
        if self.song?.id == song.id { self.song = song }
        if armed?.song.id == song.id { armed?.song = song }
    }

    private func switchTo(_ song: Song, in show: Show, at position: Double, play: Bool) {
        self.song = song
        self.show = show
        let token = UUID()
        loadToken = token
        disarm()
        arms = [:]
        guard audio.isRunning else {
            pause()
            retire(buffers)
            buffers = nil
            buffersSongID = nil
            timecodeGenerated = song.hasTimecode && song.timecodePath == nil
            source = !song.hasTimecode ? .none : (song.timecodePath == nil ? .generated : .file((song.timecodePath! as NSString).lastPathComponent))
            trackFound = false
            masterProblem = nil
            isLoading = false
            locate(position)
            if play { self.play() }
            return
        }
        if let hit = cached(song) {
            isLoading = false
            install(hit, at: position, play: play)
            return
        }
        // Not in memory (the Mac couldn't fit the whole set, or files just changed): stop, load, go.
        pause()
        isLoading = true
        Task {
            let l = await self.loaded(song, in: show, priority: .userInitiated)
            guard self.loadToken == token else { return }
            self.isLoading = false
            self.install(l, at: position, play: play)
        }
    }

    private func install(_ l: Loaded, at position: Double, play: Bool) {
        let old = buffers
        let sounding = isPlaying && usesAudio
        buffers = l.buffers
        buffersSongID = song?.id
        masterProblem = l.masterProblem
        timecodeGenerated = l.buffers.timecodeGenerated
        source = l.buffers.source
        trackFound = l.buffers.ltc != nil
        let clamped = clamp(position)
        audio.state.cut(to: l.buffers, at: frame(clamped), playing: play, fade: sounding)
        anchorPosition = clamped
        anchorTime = CACurrentMediaTime()
        setRunning(play)
        if play { armNext() }
        objectWillChange.send()
        syncClock()
        retire(old)
    }

    /// The song in memory, if it was read from the files the song names now.
    private func cached(_ song: Song) -> Loaded? {
        guard let l = cache[song.id], l.key == song.audioKey, l.buffers.sampleRate == audio.sampleRate else { return nil }
        return l
    }

    /// Reads a song into memory (or waits for the read already under way).
    private func loaded(_ song: Song, in show: Show, priority: TaskPriority) async -> Loaded {
        if let hit = cached(song) { return hit }
        let key = song.audioKey
        if let running = inFlight[song.id] {
            let l = await running.value
            if l.key == key && l.buffers.sampleRate == audio.sampleRate { return l }
        }
        let rate = audio.sampleRate
        let gen = generation
        let task = Task.detached(priority: priority) { () -> Loaded in
            let (b, problem) = SongLoader.buffers(for: song, in: show, sampleRate: rate)
            return Loaded(buffers: b, masterProblem: problem, key: key)
        }
        inFlight[song.id] = task
        let l = await task.value
        if inFlight[song.id] == task { inFlight[song.id] = nil }
        if generation == gen && audio.sampleRate == rate {
            retire(cache[song.id]?.buffers)
            cache[song.id] = l
        }
        countReady()
        return l
    }

    /// The songs to keep in memory, most needed first (the playing song, then the rest of the
    /// set). They load one at a time in the background, as many as the Mac has memory for.
    func keepReady(_ songs: [Song], in show: Show) {
        self.show = show
        wanted = songs
        scheduleWarm()
    }

    private func scheduleWarm() {
        guard warming == nil else { warmAgain = true; return }
        warming = Task { [weak self] in
            await self?.warm()
            self?.warming = nil
        }
    }

    private func warm() async {
        while true {
            warmAgain = false
            guard audio.isRunning, let show else { return }
            let keep = keptIDs()
            let keepSet = Set(keep)
            // Let go of what isn't wanted any more (never what's playing or armed).
            let busy: Set<UUID> = Set([song?.id, buffersSongID, armed?.song.id].compactMap { $0 })
            for (id, l) in cache where !keepSet.contains(id) && !busy.contains(id) {
                retire(l.buffers)
                cache[id] = nil
            }
            countReady()
            let byID = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let missing = keep.compactMap { byID[$0] }.first(where: { cached($0) == nil })
            guard let next = missing else {
                if warmAgain { continue }
                return
            }
            _ = await loaded(next, in: show, priority: .utility)
            if isPlaying { armNext() }
        }
    }

    private func keptIDs() -> [UUID] {
        let rate = audio.sampleRate
        let byID = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let budget = SetMemory.budget(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        return SetMemory.fitting(wanted.map(\.id), bytes: { id in
            if let l = self.cache[id] { return l.buffers.byteCount }
            let s = byID[id]
            return SetMemory.estimatedBytes(seconds: (s?.playLength ?? 300) + (s?.fileOffset ?? 0), sampleRate: rate)
        }, budget: budget)
    }

    private func countReady() {
        let keep = keptIDs()
        let byID = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ready = keep.filter { id in byID[id].map { cached($0) != nil } ?? false }.count
        if readyCount != ready { readyCount = ready }
        if readyTotal != keep.count { readyTotal = keep.count }
        let left = max(0, wanted.count - keep.count)
        if notKept != left { notKept = left }
    }

    /// Arms the song that should follow, so the audio runs straight into it at the last sample.
    private func armNext() {
        guard usesAudio, let b = buffers, buffersSongID == song?.id, loop == nil,
              let want = wantedNext?(), let show else { disarm(); return }
        guard let l = cached(want) else {
            disarm()
            // Not in memory yet: read it now, then arm.
            Task {
                _ = await self.loaded(want, in: show, priority: .userInitiated)
                if self.isPlaying { self.armNext() }
            }
            return
        }
        if let a = armed, a.song.id == want.id, a.loaded.buffers === l.buffers, a.after === b {
            armed?.song = want
            return
        }
        retire(armed?.loaded.buffers)
        armSerial += 1
        let a = Armed(song: want, loaded: l, after: b, serial: armSerial)
        armed = a
        arms[armSerial] = a
        arms = arms.filter { $0.key > armSerial - 4 }
        audio.state.arm(l.buffers, after: b, serial: armSerial)
        syncClock()
    }

    private func disarm() {
        guard armed != nil else { return }
        retire(armed?.loaded.buffers)
        armed = nil
        audio.state.arm(nil, after: nil, serial: 0)
        syncClock()
    }

    /// The audio ran on into the armed song: catch up with it. Nothing about the sound changes.
    private func syncAdvance() {
        let s = audio.state
        guard s.advances != seenAdvances else { return }
        seenAdvances = s.advances
        guard let a = arms[s.advancedSerial] else { return }  // from before a cut: stale
        arms = [:]
        armed = nil
        let old = buffers
        song = a.song
        buffers = a.loaded.buffers
        buffersSongID = a.song.id
        masterProblem = a.loaded.masterProblem
        timecodeGenerated = a.loaded.buffers.timecodeGenerated
        source = a.loaded.buffers.source
        trackFound = a.loaded.buffers.ltc != nil
        loop = nil
        loadToken = UUID()
        isLoading = false
        objectWillChange.send()
        syncClock()
        retire(old)
        onAdvance?(a.song)
        armNext()
    }

    /// The song being heard and its audio: the armed one once the audio has run into it, even
    /// before the main thread has caught up.
    private func audible() -> (song: Song?, buffers: PlaybackBuffers?) {
        let s = audio.state
        if s.advances != seenAdvances, let a = arms[s.advancedSerial] { return (a.song, a.loaded.buffers) }
        return (song, buffers)
    }

    /// Buffers the audio thread may still be reading are let go two seconds later, on the main
    /// thread, so freeing them never lands on the audio thread.
    private func retire(_ object: AnyObject?) {
        guard let object else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = object }
    }

    private func dropCache() {
        for l in cache.values { retire(l.buffers) }
        cache = [:]
        inFlight = [:]
        countReady()
    }

    /// The first timecode in the current song's timecode file.
    var firstFileTimecode: Timecode? { buffers?.ltc?.first }

    /// Files changed: nothing in memory is trusted any more. The app hands over the fresh set.
    func invalidateCache() {
        dropCache()
        generation += 1
        disarm()
        wanted = []
    }

    /// The timecode going out right now: read from the song's timecode file when it has one,
    /// so the clock shows exactly what the console receives. Nil where nothing is sent.
    func outputTimecode(for song: Song, at time: CFTimeInterval = CACurrentMediaTime()) -> Timecode? {
        let heard = audible()
        let playing = usesAudio && self.song?.id == song.id ? (heard.song ?? song) : song
        guard playing.hasTimecode else { return nil }
        if usesAudio, let b = heard.buffers, self.song?.id == song.id {
            switch b.source {
            case .file:
                guard let track = b.ltc else { return nil }
                let frame = Int(((position(at: time) + playing.fileOffset) * audio.sampleRate).rounded())
                return track.timecode(atSample: frame)
            case .unreadable, .none:
                return nil
            case .generated:
                break
            }
        }
        return playing.start.adding(frames: Int((position(at: time) * playing.rate.framesPerSecond + 1e-6).rounded(.down)))
    }

    // MARK: Playhead

    func position(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard usesAudio, let song = audible().song else {
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

    /// Hands the current state to the clock the MTC and Art-Net senders read.
    func syncClock() {
        clock.update(song: song, buffers: buffers, sampleRate: audio.sampleRate, latency: audio.latency, usesAudio: usesAudio,
                     clockRunning: isPlaying && !usesAudio, anchorPosition: anchorPosition, anchorTime: anchorTime,
                     arms: arms.mapValues { (song: $0.song, buffers: $0.loaded.buffers) }, seenAdvances: seenAdvances)
    }

    /// Sends test timecode on the timecode output (never the music) until stopped. Starts at
    /// the current song's start, or 01:00:00:00.
    func startTest() {
        guard audio.isRunning, !isPlaying else { return }
        let start = song.flatMap { $0.hasTimecode ? $0.start : nil } ?? Timecode("01:00:00:00", rate: .fps30)!
        let rate = audio.sampleRate
        let seconds = 300.0
        let ltc = LTC.render(start: start, frameCount: Int(seconds * start.rate.framesPerSecond), sampleRate: rate)
        audio.state.testPosition = 0
        audio.state.test = PlaybackBuffers(sampleRate: rate, master: [[Float](repeating: 0, count: ltc.count)], timecode: ltc)
        clock.setTest(start)
        testing = true
    }

    func stopTest() {
        let old = audio.state.test
        audio.state.test = nil
        clock.setTest(nil)
        testing = false
        if let old { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = old } }
    }

    func play() {
        syncAdvance()
        guard !isPlaying, song != nil else { return }
        if testing { stopTest() }
        if case .lost = status, !audio.isRunning { return }  // show-safe: no silent clock after a lost interface
        if usesAudio {
            audio.state.setPlaying(true)
        } else {
            anchorTime = CACurrentMediaTime()
        }
        setRunning(true)
        armNext()
        syncClock()
    }

    func pause() {
        syncAdvance()
        guard isPlaying else { return }
        if usesAudio {
            audio.state.setPlaying(false)
        } else {
            anchorPosition = position()
        }
        setRunning(false)
        syncClock()
        if let routing = pendingRouting { configure(routing: routing) }
    }

    private func setRunning(_ on: Bool) {
        if isPlaying != on { isPlaying = on }
        if on {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    func locate(_ seconds: Double) {
        syncAdvance()
        let clamped = clamp(seconds)
        if usesAudio { audio.state.locate(frame(clamped), fade: isPlaying) }
        anchorPosition = clamped
        anchorTime = CACurrentMediaTime()
        objectWillChange.send()
        syncClock()
    }

    private func clamp(_ seconds: Double) -> Double { max(lowerBound, min(seconds, max(length, lowerBound))) }

    /// The frame in the current song's files for a position (seconds from the song's start).
    private func frame(_ seconds: Double) -> Int {
        max(0, Int(((seconds + (song?.fileOffset ?? 0)) * audio.sampleRate).rounded()))
    }

    /// Loops between two points of the song (seconds from its start); nil stops looping.
    func setLoop(_ range: ClosedRange<Double>?) {
        syncAdvance()
        loop = range
        guard let range, usesAudio else {
            audio.state.setLoop(nil)
            if isPlaying { armNext() }
            return
        }
        disarm()
        audio.state.setLoop(LoopRegion(start: frame(range.lowerBound), end: frame(range.upperBound)))
    }

    private func tick() {
        syncAdvance()
        guard isPlaying else { return }
        // What should follow can change at any moment (the set reordered, a song skipped, stop
        // after each); check a few times a second.
        armCheck += 1
        if armCheck % 10 == 0 { armNext() }
        let p = position()
        if loop != nil && !usesAudio, let loop, p >= loop.upperBound {
            locate(loop.lowerBound)
            return
        }
        // With the next song armed, the audio runs into it by itself; this is the end of the set,
        // stop after each, or a next song that wasn't ready.
        if loop == nil, length > 0, p >= length { onSongEnd?() }
    }
}
