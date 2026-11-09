import SwiftUI

/// The Vivid glass material, ported from the website's `.glass` class: a dark surface at
/// `alpha` over a blur, a 6% top sheen, and a 1 pt edge brightest top-left fading to champagne.
/// Increase Contrast and Reduce Transparency get a solid surface with a plain border.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    /// Never below 0.64; 0.76 for bars that content passes under.
    var alpha: Double = 0.64

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background {
            if reduceTransparency || contrast == .increased {
                shape.fill(Color(hex: 0x0C0C0E))
                    .overlay(shape.strokeBorder(Brand.graphite, lineWidth: 1))
            } else {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color(hex: 0x101014).opacity(alpha))
                    shape.fill(LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0)],
                                              startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)))
                    shape.strokeBorder(
                        LinearGradient(stops: [
                            .init(color: .white.opacity(0.32), location: 0),
                            .init(color: .white.opacity(0.07), location: 0.3),
                            .init(color: .white.opacity(0.04), location: 0.7),
                            .init(color: Brand.champagne.opacity(0.22), location: 1),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 18)
            }
        }
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 16, alpha: Double = 0.64) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, alpha: alpha))
    }

    /// Solid panels: lists and editors are never glass.
    func solidPanel(cornerRadius: CGFloat = 16) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Brand.solid))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.05), lineWidth: 1))
    }
}

/// Small rounded label ("30 fps", "Rolling").
struct Chip<Leading: View>: View {
    let text: String
    let leading: () -> Leading

    init(_ text: String, @ViewBuilder leading: @escaping () -> Leading) {
        self.text = text
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: 6) {
            leading()
            Text(text)
        }
        .font(.manrope(12, .semibold))
        .foregroundStyle(Brand.steel)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

extension Chip where Leading == EmptyView {
    init(_ text: String) {
        self.text = text
        self.leading = { EmptyView() }
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(pulsing && dim ? 0.35 : 1)
            .onAppear { update() }
            .onChange(of: pulsing) { _ in update() }
    }

    private func update() {
        guard pulsing, !reduceMotion else { dim = false; return }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dim = true }
    }
}

extension Animation {
    /// The app's motion: a critically damped spring (no bounce), like SwiftUI's `.smooth`.
    static func vivid(_ duration: Double) -> Animation { .spring(response: duration, dampingFraction: 1) }
}

/// Gold bars for the playing song; they move while rolling (macOS 14 and later).
struct PlayingIndicator: View {
    var isPlaying: Bool

    var body: some View {
        if #available(macOS 14, *) {
            Image(systemName: "waveform")
                .foregroundStyle(Brand.gold)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        } else {
            Image(systemName: "waveform").foregroundStyle(Brand.gold)
        }
    }
}

/// A quiet button: off-white text on a faint fill.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(13, .semibold))
            .foregroundStyle(prominent ? Color(hex: 0x120D05) : Brand.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Brand.gold : .white.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .opacity(configuration.isPressed && prominent ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Brand.ink)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(configuration.isPressed ? 0.12 : 0.0001)))
            .contentShape(Rectangle())
    }
}

struct KeyCap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.manrope(11, .semibold))
            .foregroundStyle(Brand.steel)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
}
