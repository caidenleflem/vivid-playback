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
    var manufacturer: String = ""
    /// Names macOS gives the output channels (Dante devices often carry their channel labels).
    var channelNames: [String] = []
    /// For an aggregate device: the interfaces inside it, in output order.
    var parts: [Part] = []

    struct Part: Hashable {
        let name: String
        let outputs: Int
        let sampleRate: Double
    }

    var isAggregate: Bool { parts.count > 1 }

    /// The interface inside an aggregate that owns `channel` (1-based), and its own number there.
    func part(for channel: Int) -> (part: Part, local: Int)? {
        var first = 1
        for p in parts {
            if channel >= first && channel < first + p.outputs { return (p, channel - first + 1) }
            first += p.outputs
        }
        return nil
    }

    /// The inside interfaces don't all run at one sample rate (an aggregate like that can stay silent).
    var partsDisagreeOnRate: Bool { Set(parts.map(\.sampleRate).filter { $0 > 0 }).count > 1 }

    /// Dante Virtual Soundcard, Dante Via, or an interface from Audinate's ecosystem.
    var isDante: Bool {
        let n = name.lowercased(), m = manufacturer.lowercased()
        return n.contains("dante") || m.contains("audinate")
    }

    /// "Output 3 · FOH LTC", or just "Output 3" when the channel has no real name. On an
    /// aggregate: "Output 3 · MOTU M4 out 1", so it's clear which interface it is.
    func outputLabel(_ channel: Int) -> String {
        if isAggregate, let (p, local) = part(for: channel) { return "Output \(channel) · \(p.name) out \(local)" }
        let i = channel - 1
        guard i >= 0, i < channelNames.count else { return "Output \(channel)" }
        let n = channelNames[i].trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n == String(channel) || Int(n) != nil { return "Output \(channel)" }
        return "Output \(channel) · \(n)"
    }
}

/// Core Audio's list of output devices.
enum AudioDevices {
    /// The interfaces to choose from. The joined devices the app makes for itself are left out.
    static func all() -> [AudioDevice] { everything().filter { !$0.uid.hasPrefix(joinedPrefix) } }

    private static func everything() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device(id:))
    }

    // MARK: Master and timecode on two interfaces

    private static let joinedPrefix = "com.vividplayback.joined."

    /// Two interfaces played as one, so the master and the timecode still come from one frame
    /// counter: the master's interface first (it's the clock), then the timecode interface, kept
    /// in step with it by Core Audio's drift correction. It's the same thing as an aggregate
    /// device in Audio MIDI Setup, made the same way every time. Private: only this app sees it,
    /// and it goes away when the app quits. Nil if Core Audio won't make it.
    static func joined(master: AudioDevice, timecode: AudioDevice) -> AudioDevice? {
        let uid = joinedPrefix + "\(master.uid)+\(timecode.uid)"
        if let existing = everything().first(where: { $0.uid == uid }),
           existing.outputChannels == master.outputChannels + timecode.outputChannels {
            return existing
        }
        // Core Audio's aggregate keys, spelled out ("master" is the clock sub-device).
        let description: [String: Any] = [
            "uid": uid,
            "name": "Vivid Playback · \(master.name) + \(timecode.name)",
            "private": 1,
            "stacked": 0,
            "master": master.uid,
            "subdevices": [
                ["uid": master.uid, "drift": 0],
                ["uid": timecode.uid, "drift": 1, "drift quality": 0x7F],
            ],
        ]
        var id = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr, id != 0 else { return nil }
        // Run both at the master's rate.
        if master.sampleRate > 0 {
            var addr = address(kAudioDevicePropertyNominalSampleRate)
            var rate = Float64(master.sampleRate)
            _ = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
        }
        // Core Audio finishes setting it up a moment later.
        let expected = master.outputChannels + timecode.outputChannels
        for _ in 0..<50 {
            if let d = device(id: id), d.outputChannels >= expected { return d }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if let d = device(id: id), d.outputChannels > 0 { return d }
        _ = AudioHardwareDestroyAggregateDevice(id)
        return nil
    }

    /// Removes the joined devices the app made, except `keeping`.
    static func removeJoined(keeping uid: String? = nil) {
        for d in everything() where d.uid.hasPrefix(joinedPrefix) && d.uid != uid {
            _ = AudioHardwareDestroyAggregateDevice(d.id)
        }
    }

    static func defaultOutput() -> AudioDevice? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return device(id: id)
    }

    static func device(uid: String) -> AudioDevice? { all().first { $0.uid == uid } }

    /// Every interface present, including a joined one the app is playing on.
    static func presentUIDs() -> Set<String> { Set(everything().map(\.uid)) }

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
                           sampleRate: nominalSampleRate(id),
                           manufacturer: string(id, kAudioObjectPropertyManufacturer) ?? "",
                           channelNames: (1...max(1, channels)).map { channelName(id, $0) ?? "" },
                           parts: aggregateParts(id))
    }

    /// The interfaces inside an aggregate device, in the order its outputs are numbered.
    private static func aggregateParts(_ id: AudioDeviceID) -> [AudioDevice.Part] {
        var typeAddr = address(kAudioDevicePropertyTransportType)
        var type = UInt32(0)
        var typeSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &typeAddr, 0, nil, &typeSize, &type) == noErr,
              type == kAudioDeviceTransportTypeAggregate else { return [] }
        var addr = address(kAudioAggregateDevicePropertyFullSubDeviceList)
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value,
              let uids = value.takeRetainedValue() as? [String] else { return [] }
        return uids.compactMap { uid in
            guard let sub = deviceID(forUID: uid) else { return nil }
            let outputs = outputChannels(sub)
            guard outputs > 0 else { return nil }
            return AudioDevice.Part(name: string(sub, kAudioObjectPropertyName) ?? uid, outputs: outputs,
                                    sampleRate: nominalSampleRate(sub))
        }
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }

    /// Calls `onChange` on the main queue whenever interfaces are plugged in or unplugged.
    @discardableResult
    static func observeChanges(_ onChange: @escaping () -> Void) -> Bool {
        var addr = address(kAudioHardwarePropertyDevices)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
            onChange()
        } == noErr
    }

    /// Total output latency in frames: the device's own latency, its safety offset and the
    /// output stream's latency. (The IO buffer is added separately.)
    static func outputLatencyFrames(_ id: AudioDeviceID) -> Int {
        func u32(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Int {
            var addr = address(selector, scope: scope)
            var v = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? Int(v) : 0
        }
        var total = u32(kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeOutput)
            + u32(kAudioDevicePropertySafetyOffset, scope: kAudioDevicePropertyScopeOutput)
        // The first output stream's own latency.
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let s = streams.first {
                var a = address(kAudioStreamPropertyLatency)
                var v = UInt32(0)
                var sz = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(s, &a, 0, nil, &sz, &v) == noErr { total += Int(v) }
            }
        }
        return total
    }

    static func bufferFrames(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? Int(v) : 0
    }

    private static func channelName(_ id: AudioDeviceID, _ channel: Int) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyElementName,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(channel))
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
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
