import Foundation
import CoreAudio

/// An audio interface with outputs.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannels: Int
    let sampleRate: Double
    var inputChannels: Int = 0
}

/// Core Audio's list of output devices.
enum AudioDevices {
    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device(id:))
    }

    static func defaultOutput() -> AudioDevice? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return device(id: id)
    }

    static func device(uid: String) -> AudioDevice? { all().first { $0.uid == uid } }

    /// Devices with inputs (for reading incoming LTC).
    static func inputs() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let inputs = channels(id, scope: kAudioDevicePropertyScopeInput)
            guard inputs > 0 else { return nil }
            return AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                               name: string(id, kAudioObjectPropertyName) ?? "Audio device",
                               outputChannels: channels(id, scope: kAudioDevicePropertyScopeOutput),
                               sampleRate: nominalSampleRate(id), inputChannels: inputs)
        }
    }

    static func device(id: AudioDeviceID) -> AudioDevice? {
        let channels = outputChannels(id)
        guard channels > 0 else { return nil }
        return AudioDevice(id: id,
                           uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                           name: string(id, kAudioObjectPropertyName) ?? "Audio device",
                           outputChannels: channels,
                           sampleRate: nominalSampleRate(id))
    }

    /// Calls `onChange` on the main queue whenever interfaces are plugged in or unplugged.
    @discardableResult
    static func observeChanges(_ onChange: @escaping () -> Void) -> Bool {
        var addr = address(kAudioHardwarePropertyDevices)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
            onChange()
        } == noErr
    }

    // MARK: Helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int { channels(id, scope: kAudioDevicePropertyScopeOutput) }

    private static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }
}
