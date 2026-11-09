import Foundation
import AVFoundation
import AudioToolbox
import QuartzCore
import PlaybackCore

/// What the audio thread reads and writes. Word-sized fields only; the main thread writes
/// `pendingLocate` and the settings, the audio thread writes the position. On Apple hardware
/// aligned word loads and stores don't tear, which is all this needs.
final class RenderState: @unchecked Sendable {
    var buffers: PlaybackBuffers?
    var playing = false
    var position = 0
    /// Set by the main thread to move the playhead; taken by the audio thread at its next block.
    var pendingLocate = -1
    var map = OutputMap(channelCount: 2, masterLeft: 0, masterRight: 1, timecode: nil)
    var masterGain: Float = 1
    var timecodeGain: Float = 0.5
    var loop: LoopRegion?
    /// The position after the last block, and when that block was rendered.
    var renderedPosition = 0
    var renderedAt: Double = 0
    /// Peak level per output channel since the meters last read it (the UI resets it).
    let peaks: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        p.initialize(repeating: 0, count: 64)
        return p
    }()
    /// Test timecode for line checks: sent on the timecode output only, while stopped.
    var test: PlaybackBuffers?
    var testPosition = 0
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

        let hardware = output.outputFormat(forBus: 0)
        sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : (device.sampleRate > 0 ? device.sampleRate : 48_000)
        channelCount = max(1, hardware.channelCount > 0 ? Int(hardware.channelCount) : device.outputChannels)

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
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>?.self, capacity: list.count) { pointers in
                for i in 0..<list.count { pointers[i] = list[i].mData?.assumingMemoryBound(to: Float.self) }
                let outputs = UnsafeBufferPointer(pointers)
                let jump = state.pendingLocate
                if jump >= 0 {
                    state.position = jump
                    state.pendingLocate = -1
                }
                if state.playing {
                    state.position = Mixer.render(state.buffers, position: state.position, frames: frames, into: outputs,
                                                  map: state.map, masterGain: state.masterGain,
                                                  timecodeGain: state.timecodeGain, loop: state.loop)
                } else if let test = state.test {
                    // Line check: timecode only, never the music, looping.
                    state.testPosition = Mixer.render(test, position: state.testPosition, frames: frames, into: outputs,
                                                      map: state.map, masterGain: 0, timecodeGain: state.timecodeGain,
                                                      loop: LoopRegion(start: 0, end: test.frameCount))
                } else {
                    for p in outputs { p?.update(repeating: 0, count: frames) }
                }
                Mixer.peaks(outputs, frames: frames, into: state.peaks, count: min(64, outputs.count))
                state.renderedPosition = state.position
                state.renderedAt = CACurrentMediaTime()
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
        latency = output.presentationLatency
    }

    func stop() {
        state.playing = false
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
            let seconds = (song.length ?? 0) + song.fileOffset
            let frames = max(timecode?.count ?? 0, Int(seconds * sampleRate))
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
