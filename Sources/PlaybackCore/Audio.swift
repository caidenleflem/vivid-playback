import Foundation

public struct AudioFileInfo: Equatable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var frameCount: Int

    public init(sampleRate: Double, channelCount: Int, frameCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
    }

    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

/// Reads audio files for checking. The Mac app reads every format through AVFoundation;
/// `WAVFile` reads WAV anywhere (and in tests).
public protocol AudioFileReading: Sendable {
    func info(of url: URL) throws -> AudioFileInfo
    /// One array of samples per channel.
    func readChannels(of url: URL) throws -> (sampleRate: Double, channels: [[Float]])
}

public enum AudioFileError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .unreadable(let s): return "Couldn't read \(s)."
        case .unsupported(let s): return s
        }
    }
}

/// RIFF WAVE reading and writing: 16, 24 and 32-bit integer and 32 or 64-bit float PCM.
public struct WAVFile: AudioFileReading {
    public init() {}

    struct Format { var tag: Int; var channels: Int; var sampleRate: Double; var bits: Int }

    static func parse(_ data: Data, name: String) throws -> (Format, Range<Int>) {
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func tag(_ o: Int) -> String { String(decoding: data[o..<o + 4], as: UTF8.self) }
        guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else {
            if data.count >= 4 && tag(0) == "RF64" { throw AudioFileError.unsupported("\(name) is an RF64 file. Export it as a standard WAV.") }
            throw AudioFileError.unreadable(name)
        }
        var offset = 12
        var format: Format?
        var dataRange: Range<Int>?
        while offset + 8 <= data.count {
            let id = tag(offset)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " && body + 16 <= data.count {
                var t = u16(body)
                if t == 0xFFFE && size >= 26 { t = u16(body + 24) }  // WAVE_FORMAT_EXTENSIBLE: sub-format
                format = Format(tag: t, channels: u16(body + 2), sampleRate: Double(u32(body + 4)), bits: u16(body + 14))
            } else if id == "data" {
                dataRange = body..<min(data.count, body + size)
            }
            offset = body + size + (size & 1)
        }
        guard let f = format, let r = dataRange, f.channels > 0 else { throw AudioFileError.unreadable(name) }
        guard (f.tag == 1 && [16, 24, 32].contains(f.bits)) || (f.tag == 3 && [32, 64].contains(f.bits)) else {
            throw AudioFileError.unsupported("\(name) uses a WAV format that isn't supported (format \(f.tag), \(f.bits)-bit).")
        }
        return (f, r)
    }

    public func info(of url: URL) throws -> AudioFileInfo {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (f, r) = try Self.parse(data, name: url.lastPathComponent)
        return AudioFileInfo(sampleRate: f.sampleRate, channelCount: f.channels, frameCount: r.count / (f.bits / 8 * f.channels))
    }

    public func readChannels(of url: URL) throws -> (sampleRate: Double, channels: [[Float]]) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (f, r) = try Self.parse(data, name: url.lastPathComponent)
        let bytes = f.bits / 8
        let frames = r.count / (bytes * f.channels)
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: f.channels)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: r.lowerBound)
            for i in 0..<frames {
                for c in 0..<f.channels {
                    let p = base.advanced(by: (i * f.channels + c) * bytes)
                    let v: Float
                    switch (f.tag, f.bits) {
                    case (1, 16):
                        v = Float(Int16(bitPattern: p.loadUnaligned(as: UInt16.self).littleEndian)) / 32768
                    case (1, 24):
                        let b0 = Int32(p.load(fromByteOffset: 0, as: UInt8.self))
                        let b1 = Int32(p.load(fromByteOffset: 1, as: UInt8.self))
                        let b2 = Int32(Int8(bitPattern: p.load(fromByteOffset: 2, as: UInt8.self)))
                        v = Float(b0 | b1 << 8 | b2 << 16) / 8_388_608
                    case (1, 32):
                        v = Float(Int32(bitPattern: p.loadUnaligned(as: UInt32.self).littleEndian)) / 2_147_483_648
                    case (3, 32):
                        v = Float(bitPattern: p.loadUnaligned(as: UInt32.self).littleEndian)
                    default:
                        v = Float(Double(bitPattern: p.loadUnaligned(as: UInt64.self).littleEndian))
                    }
                    channels[c][i] = v
                }
            }
        }
        return (f.sampleRate, channels)
    }

    /// Writes integer PCM (16 or 24-bit). Used for tests and for exporting generated timecode.
    public static func write(channels: [[Float]], sampleRate: Int, bitDepth: Int = 24, to url: URL) throws {
        precondition(bitDepth == 16 || bitDepth == 24)
        let frames = channels.first?.count ?? 0
        let bytes = bitDepth / 8
        let dataSize = frames * channels.count * bytes
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels.count); u32(sampleRate)
        u32(sampleRate * channels.count * bytes); u16(channels.count * bytes); u16(bitDepth)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for i in 0..<frames {
            for ch in channels {
                let s = max(-1, min(1, ch[i]))
                if bitDepth == 16 {
                    u16(Int(UInt16(bitPattern: Int16((s * 32767).rounded()))))
                } else {
                    let v = Int32((s * 8_388_607).rounded())
                    d.append(UInt8(truncatingIfNeeded: v)); d.append(UInt8(truncatingIfNeeded: v >> 8)); d.append(UInt8(truncatingIfNeeded: v >> 16))
                }
            }
        }
        try d.write(to: url)
    }
}
