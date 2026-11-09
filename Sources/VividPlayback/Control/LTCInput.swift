import Foundation
import AVFoundation
import AudioToolbox
import QuartzCore
import PlaybackCore

/// Reads LTC from one input channel of an audio interface.
final class LTCInput {
    private var engine: AVAudioEngine?
    private var decoder: LTCStreamDecoder?

    /// `onFrame` runs on the audio input's thread with each decoded frame and when it arrived.
    func start(deviceUID: String?, channel: Int, onFrame: @escaping (LTCFrame, Double) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, let device = AudioDevices.inputs().first(where: { $0.uid == uid }), let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFileError.unsupported("That input isn't available.") }
        let decoder = LTCStreamDecoder(sampleRate: format.sampleRate)
        let index = max(0, min(channel - 1, Int(format.channelCount) - 1))
        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = decoder.process(UnsafeBufferPointer(start: data[index], count: Int(buffer.frameLength)))
            let now = CACurrentMediaTime()
            for f in frames { onFrame(f, now) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.decoder = decoder
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        decoder = nil
    }
}
