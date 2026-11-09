import Foundation

/// Writes a small example show folder (an offset sheet, masters and timecode files) so the app
/// can be tried before any real show is on hand. One song's timecode starts a frame late on
/// purpose, to show what a check finding looks like.
public enum ExampleShow {
    public static let songs: [(title: String, start: String, chord: [Double])] = [
        ("Overture", "01:00:00:00", [220.0, 277.18, 329.63]),
        ("Golden Hour", "02:00:00:00", [196.0, 246.94, 293.66]),
        ("Night Drive", "03:00:00:00", [174.61, 220.0, 261.63]),
        ("Afterglow", "04:00:00:00", [164.81, 207.65, 246.94]),
    ]

    public static func write(to folder: URL, seconds: Double = 24, sampleRate: Int = 48_000) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("Masters"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("Timecode"), withIntermediateDirectories: true)
        var csv = "Song #,Title,TC Start,FPS\n"
        let rate = FrameRate.fps30
        let sr = Double(sampleRate)
        let count = Int(seconds * sr)
        for (i, song) in songs.enumerated() {
            let n = i + 1
            let number = n < 10 ? "0\(n)" : "\(n)"
            csv += "\(n),\(song.title),\(song.start),30\n"
            // A soft chord that swells and fades, so the waveform has a shape.
            var left = [Float](repeating: 0, count: count)
            var right = [Float](repeating: 0, count: count)
            for s in 0..<count {
                let t = Double(s) / sr
                let swell = 0.35 + 0.65 * sin(.pi * t / seconds) * (0.75 + 0.25 * sin(2 * .pi * t / 3.1))
                var v = 0.0
                for (k, f) in song.chord.enumerated() { v += sin(2 * .pi * f * t + Double(k)) / Double(song.chord.count) }
                left[s] = Float(v * swell * 0.4)
                right[s] = Float(v * swell * 0.38)
            }
            try WAVFile.write(channels: [left, right], sampleRate: sampleRate, bitDepth: 16,
                              to: folder.appendingPathComponent("Masters/\(number) \(song.title).wav"))
            var start = Timecode(song.start, rate: rate)!
            if song.title == "Afterglow" { start = start.adding(frames: 1) }
            let frames = Int((seconds * rate.framesPerSecond).rounded(.up))
            let ltc = Array(LTC.render(start: start, frameCount: frames, sampleRate: sr).prefix(count))
            try WAVFile.write(channels: [ltc], sampleRate: sampleRate, bitDepth: 16,
                              to: folder.appendingPathComponent("Timecode/\(number) \(song.title) LTC.wav"))
        }
        try csv.write(to: folder.appendingPathComponent("Tour Offsets.csv"), atomically: true, encoding: .utf8)
    }
}
