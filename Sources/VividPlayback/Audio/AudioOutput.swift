import Foundation
import AVFoundation
import AudioToolbox
import QuartzCore
import os
import PlaybackCore

/// What the audio thread reads and writes.
///
/// Song switches go through one lock so they land whole: the new song, where it starts and
/// whether it plays are taken together at the start of an audio block, never half of one with
/// half of the other. The main thread holds the lock for a few instructions; the audio thread
/// only ever tries it (if it's busy, it takes the switch on the next block), so it never waits.
///
/// The rest are word-sized fields: the main thread writes the settings, the audio thread writes
/// the position. On Apple hardware aligned word loads and stores don't tear.
final class RenderState: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let l = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
        return l
    }()

    // Written by the main thread under the lock; taken by the audio thread.
    /// Whether the song plays (main thread's view; the audio thread follows at its next block).
    private(set) var playing = false
    /// Where the playhead is about to jump to (a frame), or -1. Readable from any thread.
    private(set) var pendingLocate = -1
    private(set) var loop: LoopRegion?
    private var pendingSwitch = false
    private var pendingBuffers: PlaybackBuffers?
    private var pendingFade = false
    private var pendingLocateFade = false
    private var armedNext: Arm?

    /// The song to run straight into when `after` ends. `serial` tells arms apart, so the same
    /// song twice in a row still plays twice, once.
    final class Arm {
        let after: PlaybackBuffers
        let next: PlaybackBuffers
        let serial: Int
        init(after: PlaybackBuffers, next: PlaybackBuffers, serial: Int) {
            self.after = after
            self.next = next
            self.serial = serial
        }
    }

    // Owned by the audio thread.
    private var head = Playhead()
    private var appliedPlaying = false
    private var appliedLoop: LoopRegion?
    private var armSerial = 0
    private var usedSerial = 0
    var fadeFrames = 384

    // Written by the audio thread; read anywhere.
    var map = OutputMap(channelCount: 2, masterLeft: 0, masterRight: 1, timecode: nil)
    var masterGain: Float = 1
    var timecodeGain: Float = 0.5
    /// The position after the last block, and when that block was rendered.
    var renderedPosition = 0
    var renderedAt: Double = 0
    /// Counts each time the audio thread ran on into the armed song, and which arm that was.
    private(set) var advances = 0
    private(set) var advancedSerial = 0
    /// Peak level per output channel since the meters last read it (the UI resets it).
    let peaks: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        p.initialize(repeating: 0, count: 64)
        return p
    }()
    /// Test timecode for line checks: sent on the timecode output only, while stopped.
    var test: PlaybackBuffers?
    var testPosition = 0

    // MARK: Main thread

    private func control(_ body: () -> Void) {
        os_unfair_lock_lock(lock)
        body()
        os_unfair_lock_unlock(lock)
    }

    func setPlaying(_ on: Bool) { control { playing = on } }

    func setLoop(_ region: LoopRegion?) { control { loop = region } }

    /// Moves the playhead. While playing, what was sounding fades out under the jump.
    func locate(_ frame: Int, fade: Bool) {
        control {
            pendingLocate = max(0, frame)
            pendingLocateFade = fade
        }
        renderedPosition = max(0, frame)
        renderedAt = CACurrentMediaTime()
    }

    /// Switches song in one step: the buffers, the start frame and playing or not land together.
    /// With `fade`, the song that was playing fades out underneath instead of stopping dead.
    func cut(to buffers: PlaybackBuffers?, at frame: Int, playing on: Bool, fade: Bool) {
        control {
            pendingSwitch = true
            pendingBuffers = buffers
            pendingFade = fade
            pendingLocate = max(0, frame)
            playing = on
            loop = nil
            armedNext = nil
        }
        renderedPosition = max(0, frame)
        renderedAt = CACurrentMediaTime()
    }

    /// Arms `next` to follow `after` without a gap, or disarms with nil.
    func arm(_ next: PlaybackBuffers?, after: PlaybackBuffers?, serial: Int) {
        control {
            if let next, let after { armedNext = Arm(after: after, next: next, serial: serial) } else { armedNext = nil }
        }
    }

    // MARK: Audio thread

    /// Renders one block. Realtime-safe: no allocation, no waiting.
    func render(into outputs: UnsafeBufferPointer<UnsafeMutablePointer<Float>?>, frames: Int) {
        if os_unfair_lock_trylock(lock) {
            if pendingSwitch {
                let fade = pendingFade && appliedPlaying ? fadeFrames : 0
                head.cut(to: pendingBuffers, at: max(0, pendingLocate), fade: fade)
                pendingSwitch = false
                pendingBuffers = nil
                pendingLocate = -1
            } else if pendingLocate >= 0 {
                // A jump within the song: what was sounding fades out under it while playing.
                head.cut(to: head.buffers, at: pendingLocate, fade: pendingLocateFade && appliedPlaying ? fadeFrames : 0)
                pendingLocate = -1
            }
            pendingLocateFade = false
            appliedPlaying = playing
            appliedLoop = loop
            if let a = armedNext, a.serial > usedSerial, a.after === head.buffers {
                head.next = a.next
                armSerial = a.serial
            } else {
                head.next = nil
            }
            os_unfair_lock_unlock(lock)
        }
        if appliedPlaying {
            let before = head.advances
            Mixer.render(&head, frames: frames, into: outputs, map: map, masterGain: masterGain,
                         timecodeGain: timecodeGain, loop: appliedLoop)
            if head.advances != before {
                usedSerial = armSerial
                advancedSerial = armSerial
                advances &+= 1
            }
        } else if let test {
            head.endFade()
            // Line check: timecode only, never the music, looping.
            testPosition = Mixer.render(test, position: testPosition, frames: frames, into: outputs,
                                        map: map, masterGain: 0, timecodeGain: timecodeGain,
                                        loop: LoopRegion(start: 0, end: test.frameCount))
        } else {
            head.endFade()
            for p in outputs { p?.update(repeating: 0, count: frames) }
        }
        Mixer.peaks(outputs, frames: frames, into: peaks, count: min(64, outputs.count))
        renderedPosition = head.position
        renderedAt = CACurrentMediaTime()
    }
}

enum AudioOutputError: Error, CustomStringConvertible {
    case noOutputUnit
    case cantSelect(String, OSStatus)
    case cantStart(String, Error)

    var description: String {
        switch self {
        case .noOutputUnit: return "The audio system isn't available."
        case .cantSelect(let name, let status): return "Couldn't use \(name) (error \(status))."
        case .cantStart(let name, let error): return "Couldn't start \(name): \(error.localizedDescription)"
        }
    }
}

/// One AVAudioEngine with a single source node. Every output channel is rendered by the
/// tested `Mixer` from one frame counter, so the master and the timecode can't drift apart.
final class AudioOutput {
    private(set) var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    let state = RenderState()
    private(set) var device: AudioDevice?
    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount = 2
    /// Seconds between rendering a sample and hearing it.
    private(set) var latency: Double = 0

    var isRunning: Bool { source != nil && engine.isRunning }

    func start(on device: AudioDevice) throws {
        stop()
        engine = AVAudioEngine()
        let output = engine.outputNode
        guard let unit = output.audioUnit else { throw AudioOutputError.noOutputUnit }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AudioOutputError.cantSelect(device.name, status) }

        // The engine's own idea of the output format can still be the old device's (it's read
        // when the engine is made, on the system output). Ask the output unit for the device's
        // side after the switch, and trust Core Audio's count of the device's outputs over both.
        var deviceSide = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let unitRead = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                                            &deviceSide, &size) == noErr
        let hardware = output.outputFormat(forBus: 0)
        let rates = [device.sampleRate, unitRead ? deviceSide.mSampleRate : 0, hardware.sampleRate]
        sampleRate = rates.first { $0 > 0 } ?? 48_000
        let counts = [device.outputChannels, unitRead ? Int(deviceSide.mChannelsPerFrame) : 0, Int(hardware.channelCount)]
        channelCount = max(1, counts.first { $0 > 0 } ?? 2)

        let format: AVAudioFormat
        if channelCount <= 2 {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))!
        } else {
            // Discrete channels in order: channel n of the node is output n of the interface.
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channelCount))!
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        }

        let state = self.state
        state.map.channelCount = channelCount
        state.fadeFrames = Mixer.cutFadeFrames(sampleRate: sampleRate)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>?.self, capacity: list.count) { pointers in
                for i in 0..<list.count { pointers[i] = list[i].mData?.assumingMemoryBound(to: Float.self) }
                state.render(into: UnsafeBufferPointer(pointers), frames: frames)
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: output, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            throw AudioOutputError.cantStart(device.name, error)
        }
        source = node
        self.device = device
        // What you hear lags what was just rendered by the device's latency and one IO buffer.
        // Dante Virtual Soundcard adds its own buffering, reported through the same properties.
        let deviceFrames = AudioDevices.outputLatencyFrames(device.id)
        let ioFrames = AudioDevices.bufferFrames(device.id)
        latency = max(output.presentationLatency, Double(deviceFrames) / sampleRate) + Double(ioFrames) / sampleRate
    }

    func stop() {
        state.setPlaying(false)
        if engine.isRunning { engine.stop() }
        if let source { engine.detach(source) }
        source = nil
    }
}

/// Reads song files into buffers at the interface's sample rate.
enum SongLoader {
    static func read(_ url: URL, sampleRate target: Double) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard file.length > 0, let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        var buffer = input
        if inFormat.sampleRate != target {
            guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target,
                                                channels: inFormat.channelCount, interleaved: false),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw AudioFileError.unsupported("\(url.lastPathComponent) can't be converted to \(Int(target)) Hz.")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            let capacity = AVAudioFrameCount(Double(input.frameLength) * target / inFormat.sampleRate) + 4096
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
            var fed = false
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            buffer = output
        }
        guard let data = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
    }

    /// The master and the timecode for `song`, ready to play, plus anything that went wrong.
    /// A song with a timecode file plays that file or no timecode at all: never generated
    /// timecode in its place. A master that can't be read plays as silence, and says so.
    static func buffers(for song: Song, in show: Show, sampleRate: Double) -> (PlaybackBuffers, masterProblem: String?) {
        var master: [[Float]] = []
        var masterProblem: String?
        if song.masterPath != nil {
            if let url = show.url(forMediaPath: song.masterPath) {
                do { master = try read(url, sampleRate: sampleRate) } catch { masterProblem = problem(url, error) }
                if master.isEmpty && masterProblem == nil { masterProblem = "\(url.lastPathComponent) has no audio in it." }
            } else {
                masterProblem = "The master's location isn't known. Relink the media folder or choose the file again."
            }
        }
        var timecode: [Float]?
        var tcName: String?
        var tcProblem: String?
        if song.hasTimecode, song.timecodePath != nil {
            if let url = show.url(forMediaPath: song.timecodePath) {
                tcName = url.lastPathComponent
                do {
                    let channels = try read(url, sampleRate: sampleRate)
                    if channels.isEmpty {
                        tcProblem = "\(url.lastPathComponent) has no audio in it."
                    } else {
                        let index = song.timecodeFileChannel ?? (channels.count == 1 ? 0 :
                            LTCAnalyzer.analyze(channels: channels.map { Array($0.prefix(Int(sampleRate * 20))) }, sampleRate: sampleRate)?.channel ?? 0)
                        timecode = channels[min(index, channels.count - 1)]
                    }
                } catch {
                    tcProblem = problem(url, error)
                }
            } else {
                tcProblem = "The timecode file's location isn't known. Relink the media folder or choose the file again."
            }
        }
        if master.isEmpty {
            // No master: silence as long as the timecode file, or the sheet's length when there's
            // no audio at all yet.
            let seconds = (song.length ?? 0) + song.fileOffset
            let frames = timecode?.count ?? Int(seconds * sampleRate)
            master = [[Float](repeating: 0, count: frames)]
        }
        let b = PlaybackBuffers.prepare(song: song, sampleRate: sampleRate, master: master, timecode: timecode,
                                        timecodeFile: tcName, timecodeFileProblem: tcProblem)
        return (b, masterProblem)
    }

    private static func problem(_ url: URL, _ error: Error) -> String {
        if !FileManager.default.fileExists(atPath: url.path) {
            return "\(url.lastPathComponent) isn't where the show expects it. Relink the media folder or choose the file again."
        }
        return "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
    }
}
