import SwiftUI
import AppKit
import CoreText
import PlaybackCore

/// Vivid brand colors (the same tokens as the website).
enum Brand {
    static let black = Color.black
    static let phantom = Color(hex: 0x1E1E24)
    static let solid = Color(hex: 0x0E0E11)
    static let window = Color(hex: 0x08080A)
    static let ink = Color(hex: 0xF7F7F7)
    static let gold = Color(hex: 0xC39C67)
    static let champagne = Color(hex: 0xDBD1C5)
    static let steel = Color(hex: 0xBCBFCC)
    static let space = Color(hex: 0x9DA2B3)
    static let graphite = Color(hex: 0x6E7180)
    static let arsenic = Color(hex: 0x40424D)
    static let ok = Color(hex: 0x5BC48A)
    static let warn = Color(hex: 0xE2A852)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Font {
    static func manrope(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Manrope", size: size).weight(weight)
    }
}

enum Fonts {
    /// The app bundle registers Manrope through ATSApplicationFontsPath. Running from Xcode or
    /// `swift run` there's no bundle, so register the files from the source tree.
    static func register() {
        if NSFont(name: "Manrope-Regular", size: 12) != nil { return }
        var folders: [URL] = []
        if let res = Bundle.main.resourceURL { folders.append(res.appendingPathComponent("Fonts")) }
        folders.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts"))
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in files where url.pathExtension.lowercased() == "ttf" {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
            if NSFont(name: "Manrope-Regular", size: 12) != nil { return }
        }
    }
}

/// Generated artwork for a song: two soft pools of brand-adjacent color on near-black.
struct SongArt: View {
    let song: Song
    var cornerRadius: CGFloat = 6

    static let palette: [(UInt32, UInt32)] = [
        (0xC39C67, 0x2A2A33), (0xE3B878, 0x7A4E2A), (0x5C6B8A, 0xC39C67), (0xD98E5F, 0x3B2A40),
        (0xDBD1C5, 0x6E7180), (0x7D8FB3, 0x1E1E24), (0x8A6B4A, 0x20202A), (0x7FA3A6, 0xC39C67),
        (0xB07A8C, 0x2E3040), (0x7A2E3A, 0xC39C67), (0x9DA2B3, 0x5A4632), (0xF2D3A0, 0xC39C67),
    ]

    static func colors(for song: Song) -> (Color, Color) {
        let key = song.number.map { $0 - 1 } ?? song.title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let pair = palette[((key % palette.count) + palette.count) % palette.count]
        return (Color(hex: pair.0), Color(hex: pair.1))
    }

    var body: some View {
        let (c1, c2) = Self.colors(for: song)
        GeometryReader { geo in
            let size = max(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1B1B21), Color(hex: 0x0B0B0E)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [c1, c1.opacity(0)], center: UnitPoint(x: 0.18, y: 0.12), startRadius: 0, endRadius: size * 0.7)
                RadialGradient(colors: [c2, c2.opacity(0)], center: UnitPoint(x: 0.92, y: 1.0), startRadius: 0, endRadius: size * 0.75)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// The soft, blurred color field behind the glass, taken from the current song.
struct Ambient: View {
    let song: Song?

    var body: some View {
        let (c1, c2) = song.map(SongArt.colors) ?? (Brand.gold, Color(hex: 0x5C6B8A))
        GeometryReader { geo in
            ZStack {
                Brand.window
                Circle().fill(c1).frame(width: geo.size.width * 0.55).position(x: geo.size.width * 0.3, y: geo.size.height * 0.12)
                Circle().fill(c2).frame(width: geo.size.width * 0.6).position(x: geo.size.width * 0.82, y: geo.size.height * 0.4)
            }
            .blur(radius: 120)
            .opacity(0.5)
        }
        .ignoresSafeArea()
        .animation(.vivid(0.9), value: song?.id)
    }
}
