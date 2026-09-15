import AppKit
import SwiftUI

enum Theme {
    static let accentNS = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.0, alpha: 1)
    static let accent = Color(nsColor: accentNS)
    static let ink = Color(nsColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    static let inkSecondary = Color(nsColor: NSColor(srgbRed: 0.44, green: 0.45, blue: 0.48, alpha: 1))
    static let card = Color.white.opacity(0.62)
    static let cardStroke = Color.black.opacity(0.06)
    static let hairline = Color.black.opacity(0.08)
    static let control = Color(nsColor: NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1))
    static let windowCorner: CGFloat = 26
    static let cardCorner: CGFloat = 14

    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint ?? .clear)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
    }
}

struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.cardCorner

    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = Theme.cardCorner, tint: Color? = nil) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint))
    }

    func card(cornerRadius: CGFloat = Theme.cardCorner) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(isEnabled ? Theme.accent : Theme.accent.opacity(0.35))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .shadow(color: Theme.accent.opacity(isEnabled ? 0.28 : 0), radius: 10, y: 4)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0.06)))
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.ink.opacity(0.8))
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Circle())
    }
}

struct SegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let selected = option.0 == selection
                Text(option.1)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white)
                                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { selection = option.0 }
                    }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.control))
    }
}
