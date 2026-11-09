import Foundation
import CoreMIDI
import PlaybackCore

struct MIDIEndpoint: Identifiable, Hashable {
    let id: Int32   // CoreMIDI unique ID
    let name: String
}

/// CoreMIDI: a virtual "Vivid Playback" source other apps can listen to, sending to a chosen
/// destination, and listening to every input for remote control and incoming MIDI timecode.
final class MIDIService: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var outPort = MIDIPortRef()
    private var inPort = MIDIPortRef()
    private(set) var virtualSource = MIDIEndpointRef()
    private let lock = NSLock()
    private var receiver: (([UInt8]) -> Void)?
    var onSetupChange: (() -> Void)?
    private(set) var available = false

    init() {
        let status = MIDIClientCreateWithBlock("Vivid Playback" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async {
                self?.connectSources()
                self?.onSetupChange?()
            }
        }
        guard status == noErr else { return }
        MIDIOutputPortCreate(client, "Vivid Playback Out" as CFString, &outPort)
        MIDISourceCreate(client, "Vivid Playback" as CFString, &virtualSource)
        MIDIInputPortCreateWithBlock(client, "Vivid Playback In" as CFString, &inPort) { [weak self] list, _ in
            self?.handle(list)
        }
        available = true
        connectSources()
    }

    /// Messages arrive on CoreMIDI's thread.
    func setReceiver(_ r: (([UInt8]) -> Void)?) {
        lock.lock(); receiver = r; lock.unlock()
    }

    static func destinations() -> [MIDIEndpoint] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { endpoint(MIDIGetDestination($0)) }
    }

    static func sources() -> [MIDIEndpoint] {
        (0..<MIDIGetNumberOfSources()).compactMap { endpoint(MIDIGetSource($0)) }
    }

    private static func endpoint(_ ref: MIDIEndpointRef) -> MIDIEndpoint? {
        guard ref != 0 else { return nil }
        var id: Int32 = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &id)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        return MIDIEndpoint(id: id, name: (name?.takeRetainedValue() as String?) ?? "MIDI port")
    }

    private func connectSources() {
        guard available else { return }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if src != virtualSource { MIDIPortConnectSource(inPort, src, nil) }
        }
    }

    /// Sends to the chosen destination (if any) and always out of the virtual source.
    func send(_ bytes: [UInt8], to destinationID: Int32?) {
        guard available, !bytes.isEmpty else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        buffer.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            let packet = MIDIPacketListInit(list)
            _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list, 512, packet, 0, bytes.count, $0.baseAddress!) }
            if let id = destinationID {
                var ref = MIDIObjectRef()
                var type = MIDIObjectType.destination
                if MIDIObjectFindByUniqueID(id, &ref, &type) == noErr, ref != 0 { MIDISend(outPort, ref, list) }
            }
            MIDIReceived(virtualSource, list)
        }
    }

    private func handle(_ list: UnsafePointer<MIDIPacketList>) {
        lock.lock(); let receiver = self.receiver; lock.unlock()
        guard let receiver else { return }
        for packet in list.unsafeSequence() {
            let length = Int(packet.pointee.length)
            let data = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!)
            let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
            for message in MIDIBytes.split(bytes) { receiver(message) }
        }
    }
}
