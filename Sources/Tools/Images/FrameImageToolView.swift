import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FrameImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var backgroundKind: Kind = .color
    @State private var color = Color.white
    @State private var gradientA = Color(red: 1.0, green: 0.6, blue: 0.2)
    @State private var gradientB = Color(red: 0.95, green: 0.25, blue: 0.45)
    @State private var gradientAngle: Double = 45
    @State private var backgroundImageURL: URL?
    @State private var backgroundImage: CGImage?
    @State private var backgroundBlur: Double = 30
    @State private var aspect = AspectPreset.all[1]
    @State private var padding: Double = 0.08
    @State private var corner: Double = 24
    @State private var shadow: Double = 24
    @State private var rendered: NSImage?
    @State private var renderTask: Task<Void, Never>?

    enum Kind: String, CaseIterable, Identifiable {
        case color, gradient, image
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1400))
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: document.original != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let rendered {
                    Image(nsImage: rendered).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Background") {
                Picker("", selection: $backgroundKind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch backgroundKind {
                case .color:
                    ColorSwatchPicker(title: "Color", color: $color)
                case .gradient:
                    ColorSwatchPicker(title: "Start", color: $gradientA)
                    ColorSwatchPicker(title: "End", color: $gradientB)
                    LabeledSlider(title: "Angle", value: $gradientAngle, range: 0...360) { String(format: "%.0f°", $0) }
                case .image:
                    HStack {
                        Text(backgroundImageURL?.lastPathComponent ?? "Same photo, blurred").font(.callout).lineLimit(1)
                        Spacer()
                        Button("Choose…") { chooseBackground() }
                    }
                    LabeledSlider(title: "Blur", value: $backgroundBlur, range: 0...100) { String(format: "%.0f", $0) }
                }
            }
            SidebarSection(title: "Canvas") {
                Picker("Aspect ratio", selection: $aspect) {
                    ForEach(AspectPreset.all.filter { $0.ratio != nil }) { Text($0.title).tag($0) }
                }
                LabeledSlider(title: "Spacing", value: $padding, range: 0...0.3) { String(format: "%.0f%%", $0 * 100) }
                LabeledSlider(title: "Corner radius", value: $corner, range: 0...200) { String(format: "%.0f px", $0) }
                LabeledSlider(title: "Shadow", value: $shadow, range: 0...120) { String(format: "%.0f", $0) }
            }
        }
        .onChange(of: document.preview) { _ in scheduleRender() }
        .onChange(of: backgroundKind) { _ in scheduleRender() }
        .onChange(of: color) { _ in scheduleRender() }
        .onChange(of: gradientA) { _ in scheduleRender() }
        .onChange(of: gradientB) { _ in scheduleRender() }
        .onChange(of: gradientAngle) { _ in scheduleRender() }
        .onChange(of: backgroundBlur) { _ in scheduleRender() }
        .onChange(of: aspect) { _ in scheduleRender() }
        .onChange(of: padding) { _ in scheduleRender() }
        .onChange(of: corner) { _ in scheduleRender() }
        .onChange(of: shadow) { _ in scheduleRender() }
        .onChange(of: backgroundImageURL) { _ in scheduleRender() }
    }

    private func options(scale: CGFloat, source: CGImage) -> ImageOps.FrameOptions {
        var options = ImageOps.FrameOptions()
        if let ratio = aspect.ratio {
            options.aspect = ratio < 0 ? CGSize(width: source.width, height: source.height) : CGSize(width: ratio, height: 1)
        }
        options.padding = padding
        options.cornerRadius = corner * scale
        options.shadow = shadow * scale
        switch backgroundKind {
        case .color: options.background = .color(color.nsColor)
        case .gradient: options.background = .gradient(gradientA.nsColor, gradientB.nsColor, angle: gradientAngle)
        case .image: options.background = .image(backgroundImage ?? source, blur: backgroundBlur * scale)
        }
        return options
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil), let original = document.original else { return }
        let scale = CGFloat(cg.width) / CGFloat(original.width)
        let opts = options(scale: scale, source: cg)
        renderTask = Task.detached(priority: .userInitiated) {
            guard let framed = ImageOps.framed(cg, options: opts), !Task.isCancelled else { return }
            let ns = ImageOps.nsImage(framed)
            await MainActor.run { rendered = ns }
        }
    }

    private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = try? ImageIOBridge.load(url, maxPixelSize: 3000) else { return }
        backgroundImageURL = url
        backgroundImage = image
    }

    private func save() {
        guard let original = document.original else { return }
        let opts = options(scale: 1, source: original)
        let format: FileFormat = backgroundKind == .color && color.nsColor.alphaComponent >= 1 ? ImageToolSupport.outputFormat(for: session.primary) : .png
        ImageToolSupport.save(session, suffix: "framed", format: format) {
            guard let framed = ImageOps.framed(original, options: opts) else { throw SatsumaError.encodeFailed("Rendering failed") }
            return framed
        }
    }
}
