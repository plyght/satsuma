import AppKit
import SwiftUI

enum Theme {
    static let accentNS = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.0, alpha: 1)
    static let accent = Color(nsColor: accentNS)

    static let ink = Color(nsColor: .labelColor)
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)
    static let cardCorner: CGFloat = 12

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.cardCorner

    func body(content: Content) -> some View {
        content
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
    }
}

extension View {
    func card(cornerRadius: CGFloat = Theme.cardCorner) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

struct SegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
