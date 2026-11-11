import Foundation

// MARK: MIDI timecode

/// MIDI timecode (MTC) messages: quarter frames while running, a full-frame message on locate.
public enum MTC {
    /// The rate code MTC carries. 23.976 is sent as 24 and 29.97 non-drop as 30, as consoles expect.
    public static func rateCode(_ rate: FrameRate) -> UInt8 {
        switch rate {
        case .fps23_976, .fps24: return 0
        case .fps25: return 1
        case .fps29_97DF: return 2
        case .fps29_97, .fps30: return 3
        }
    }

    public static func rate(fromCode code: UInt8) -> FrameRate {
        switch code & 3 {
        case 0: return .fps24
        case 1: return .fps25
        case 2: return .fps29_97DF
        default: return .fps30
        }
    }

    /// F0 7F 7F 01 01 hh mm ss ff F7 (hh carries the rate in bits 5–6).
    public static func fullFrame(_ tc: Timecode) -> [UInt8] {
        let c = tc.components
        return [0xF0, 0x7F, 0x7F, 0x01, 0x01, (rateCode(tc.rate) << 5) | UInt8(c.hours), UInt8(c.minutes), UInt8(c.seconds), UInt8(c.frames), 0xF7]
    }

    /// One quarter-frame message (F1 + data). Pieces 0–7 together carry `tc`, the frame on
    /// which piece 0 was sent; a full set takes two frames.
    public static func quarterFrame(_ piece: Int, of tc: Timecode) -> [UInt8] {
        let c = tc.components
        let value: Int
        switch piece & 7 {
        case 0: value = c.frames & 0x0F
        case 1: value = c.frames >> 4
        case 2: value = c.seconds & 0x0F
        case 3: value = c.seconds >> 4
        case 4: value = c.minutes & 0x0F
        case 5: value = c.minutes >> 4
        case 6: value = c.hours & 0x0F
        default: value = (c.hours >> 4) | (Int(rateCode(tc.rate)) << 1)
        }
        return [0xF1, UInt8(((piece & 7) << 4) | (value & 0x0F))]
    }
}

/// Reads incoming MIDI timecode (quarter frames and full frames).
public struct MTCReader: Sendable {
    private var pieces = [Int](repeating: 0, count: 8)
    private var seen: UInt8 = 0
    private var lastPiece = -1
    public private(set) var rate: FrameRate = .fps30

    public init() {}

    /// Feed one MIDI message. Returns a timecode when one is complete.
    public mutating func receive(_ bytes: [UInt8]) -> Timecode? {
        if bytes.count >= 10, bytes[0] == 0xF0, bytes[1] == 0x7F, bytes[3] == 0x01, bytes[4] == 0x01 {
            rate = MTC.rate(fromCode: (bytes[5] >> 5) & 3)
            seen = 0
            lastPiece = -1
            return Timecode(hours: Int(bytes[5] & 0x1F), minutes: Int(bytes[6]), seconds: Int(bytes[7]), frames: Int(bytes[8]), rate: rate)
        }
        guard bytes.count >= 2, bytes[0] == 0xF1 else { return nil }
        let piece = Int(bytes[1] >> 4)
        // Pieces must arrive in order (forward playback); anything else starts over.
        if piece != (lastPiece + 1) % 8 && piece != 0 { seen = 0; lastPiece = -1; return nil }
        if piece == 0 { seen = 0 }
        pieces[piece] = Int(bytes[1] & 0x0F)
        seen |= 1 << piece
        lastPiece = piece
        guard piece == 7, seen == 0xFF else { return nil }
        rate = MTC.rate(fromCode: UInt8((pieces[7] >> 1) & 3))
        let tc = Timecode(hours: pieces[6] | ((pieces[7] & 1) << 4), minutes: pieces[4] | (pieces[5] << 4),
                          seconds: pieces[2] | (pieces[3] << 4), frames: pieces[0] | (pieces[1] << 4), rate: rate)
        // The set describes the frame two frames ago.
        return tc?.adding(frames: 2)
    }
}

// MARK: MIDI Machine Control

public enum MMCCommand: Equatable, Sendable {
    case stop, play, fastForward, rewind, locate(hours: Int, minutes: Int, seconds: Int, frames: Int)

    /// F0 7F <device> 06 <command> … F7
    public static func parse(_ bytes: [UInt8]) -> MMCCommand? {
        guard bytes.count >= 6, bytes[0] == 0xF0, bytes[1] == 0x7F, bytes[3] == 0x06 else { return nil }
        switch bytes[4] {
        case 0x01: return .stop
        case 0x02, 0x03: return .play
        case 0x04: return .fastForward
        case 0x05: return .rewind
        case 0x44:
            guard bytes.count >= 12, bytes[5] == 0x06, bytes[6] == 0x01 else { return nil }
            return .locate(hours: Int(bytes[7] & 0x1F), minutes: Int(bytes[8]), seconds: Int(bytes[9]), frames: Int(bytes[10] & 0x1F))
        default: return nil
        }
    }
}

// MARK: Art-Net timecode

public enum ArtNetTimecode {
    public static let port: UInt16 = 6454

    public static func rateCode(_ rate: FrameRate) -> UInt8 { MTC.rateCode(rate) }

    /// An ArtTimeCode packet (OpCode 0x9700).
    public static func packet(_ tc: Timecode) -> [UInt8] {
        let c = tc.components
        return Array("Art-Net".utf8) + [0, 0x00, 0x97, 0, 14, 0, 0,
                                         UInt8(c.frames), UInt8(c.seconds), UInt8(c.minutes), UInt8(c.hours), rateCode(tc.rate)]
    }

    public static func parse(_ data: [UInt8]) -> Timecode? {
        guard data.count >= 19, Array(data[0..<8]) == Array("Art-Net".utf8) + [0], data[8] == 0x00, data[9] == 0x97 else { return nil }
        let rate = MTC.rate(fromCode: data[18])
        return Timecode(hours: Int(data[17]), minutes: Int(data[16]), seconds: Int(data[15]), frames: Int(data[14]), rate: rate)
    }
}

// MARK: OSC

public enum OSCValue: Equatable, Sendable {
    case int(Int32), float(Float), string(String)

    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .float(let f): return Double(f)
        case .string(let s): return Double(s)
        }
    }

    public var text: String {
        switch self {
        case .int(let i): return String(i)
        case .float(let f): return String(f)
        case .string(let s): return s
        }
    }
}

public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCValue]

    public init(_ address: String, _ arguments: [OSCValue] = []) {
        self.address = address
        self.arguments = arguments
    }

    /// The command after "/vivid/" in the address, lowercased, wherever "vivid" sits: a desk's
    /// OSC line can put its own prefix in front ("/gma3/vivid/go" is "go"). Nil for anything else.
    public var vividCommand: String? {
        let parts = address.lowercased().split(separator: "/")
        guard let i = parts.firstIndex(of: "vivid"), i + 1 == parts.count - 1 else { return nil }
        return String(parts[i + 1])
    }

    public func encoded() -> [UInt8] {
        func padded(_ s: String) -> [UInt8] {
            var b = Array(s.utf8) + [0]
            while b.count % 4 != 0 { b.append(0) }
            return b
        }
        var tags = ","
        var body: [UInt8] = []
        for a in arguments {
            switch a {
            case .int(let i): tags += "i"; body += withUnsafeBytes(of: i.bigEndian, Array.init)
            case .float(let f): tags += "f"; body += withUnsafeBytes(of: f.bitPattern.bigEndian, Array.init)
            case .string(let s): tags += "s"; body += padded(s)
            }
        }
        return padded(address) + padded(tags) + body
    }

    /// Parses a packet: one message, or a bundle of them.
    public static func parse(_ data: [UInt8]) -> [OSCMessage] {
        var pos = 0
        func string() -> String? {
            guard let end = data[pos...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: data[pos..<end], as: UTF8.self)
            pos = (end + 4) & ~3
            return pos <= data.count ? s : nil
        }
        func u32() -> UInt32? {
            guard pos + 4 <= data.count else { return nil }
            let v = UInt32(data[pos]) << 24 | UInt32(data[pos + 1]) << 16 | UInt32(data[pos + 2]) << 8 | UInt32(data[pos + 3])
            pos += 4
            return v
        }
        guard !data.isEmpty, let head = string() else { return [] }
        if head == "#bundle" {
            pos += 8  // time tag
            var out: [OSCMessage] = []
            while let size = u32(), pos + Int(size) <= data.count, size > 0 {
                out += parse(Array(data[pos..<pos + Int(size)]))
                pos += Int(size)
            }
            return out
        }
        guard head.hasPrefix("/") else { return [] }
        var args: [OSCValue] = []
        if pos < data.count, let tags = string(), tags.hasPrefix(",") {
            for t in tags.dropFirst() {
                switch t {
                case "i": guard let v = u32() else { return [] }; args.append(.int(Int32(bitPattern: v)))
                case "f": guard let v = u32() else { return [] }; args.append(.float(Float(bitPattern: v)))
                case "s": guard let s = string() else { return [] }; args.append(.string(s))
                case "T": args.append(.int(1))
                case "F": args.append(.int(0))
                default: return [OSCMessage(head, args)]
                }
            }
        }
        return [OSCMessage(head, args)]
    }
}

/// What a remote can ask for.
public enum RemoteCommand: Equatable, Sendable {
    case play, stop, toggle, next, previous, top, marker
    case song(number: Int)
    case songTitle(String)
    case locate(String)
    case stopAfterEach(Bool)

    /// Reads `/vivid/<command> [argument]`. A trigger whose value is 0 (a button released) is ignored.
    public static func from(_ m: OSCMessage) -> RemoteCommand? {
        guard let command = m.vividCommand else { return nil }
        let first = m.arguments.first
        let released = first?.number == 0 && first.map { if case .string = $0 { return false } else { return true } } == true
        switch command {
        case "go", "play": return released ? nil : .play
        case "stop", "pause": return released ? nil : .stop
        case "toggle": return released ? nil : .toggle
        case "next": return released ? nil : .next
        case "prev", "previous", "back": return released ? nil : .previous
        case "top": return released ? nil : .top
        case "marker": return released ? nil : .marker
        case "song":
            guard let a = first else { return nil }
            if let n = a.number, n == n.rounded(), n > 0 { return .song(number: Int(n)) }
            return .songTitle(a.text)
        case "locate", "goto":
            guard let a = first else { return nil }
            return .locate(a.text)
        case "stopafter":
            return .stopAfterEach((first?.number ?? 1) != 0)
        default:
            return nil
        }
    }
}

// MARK: MIDI byte streams

public enum MIDIBytes {
    /// Splits a packet's bytes into whole messages (SysEx included). Running status isn't used
    /// by anything this app listens to and is dropped.
    public static func split(_ data: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i < data.count {
            let status = data[i]
            guard status & 0x80 != 0 else { i += 1; continue }
            var length: Int
            switch status {
            case 0xF0:
                let end = data[i...].firstIndex(of: 0xF7) ?? (data.count - 1)
                length = end - i + 1
            case 0xF1, 0xF3: length = 2
            case 0xF2: length = 3
            case 0xF4...0xFF: length = 1
            default:
                switch status & 0xF0 {
                case 0xC0, 0xD0: length = 2
                default: length = 3
                }
            }
            length = min(length, data.count - i)
            out.append(Array(data[i..<i + length]))
            i += length
        }
        return out
    }
}

/// A button or pad learned for a remote action: a note-on or a control change (value > 0).
public struct MIDITrigger: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case note, controlChange }
    public var kind: Kind
    public var channel: Int
    public var number: Int

    public init(kind: Kind, channel: Int, number: Int) {
        self.kind = kind
        self.channel = channel
        self.number = number
    }

    /// The trigger a message is, if it's a press (note-on with velocity, CC above 0).
    public init?(message m: [UInt8]) {
        guard m.count >= 3 else { return nil }
        switch m[0] & 0xF0 {
        case 0x90 where m[2] > 0: kind = .note
        case 0xB0 where m[2] > 0: kind = .controlChange
        default: return nil
        }
        channel = Int(m[0] & 0x0F) + 1
        number = Int(m[1])
    }

    public var displayName: String {
        switch kind {
        case .note:
            let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
            return "Note \(names[number % 12])\(number / 12 - 1) · ch \(channel)"
        case .controlChange:
            return "CC \(number) · ch \(channel)"
        }
    }
}
