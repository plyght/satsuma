import CoreImage
import SwiftUI

@MainActor
struct EditImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var adjustments = PhotoAdjustments()
    @State private var rendered: NSImage?
    @State private var showOriginal = false
    @State private var renderTask: Task<Void, Never>?

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1800))
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: document.original != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let image = (showOriginal ? document.preview : rendered) ?? document.preview {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(showOriginal ? "Showing original" : "Hold to compare") {}
                            .buttonStyle(.bordered)
                            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in showOriginal = true }.onEnded { _ in showOriginal = false })
                            .padding(12)
                    }
                }
            }
        } sidebar: {
            SidebarSection(title: "Light") {
                LabeledSlider(title: "Exposure", value: $adjustments.exposure, range: -2...2)
                LabeledSlider(title: "Brightness", value: $adjustments.brightness, range: -0.5...0.5)
                LabeledSlider(title: "Contrast", value: $adjustments.contrast, range: 0.5...1.5)
                LabeledSlider(title: "Highlights", value: $adjustments.highlights, range: 0.3...1)
                LabeledSlider(title: "Shadows", value: $adjustments.shadows, range: -1...1)
            }
            SidebarSection(title: "Color") {
                LabeledSlider(title: "Saturation", value: $adjustments.saturation, range: 0...2)
                LabeledSlider(title: "Vibrance", value: $adjustments.vibrance, range: -1...1)
                LabeledSlider(title: "Temperature", value: $adjustments.temperature, range: 3000...10000) { String(format: "%.0fK", $0) }
                LabeledSlider(title: "Tint", value: $adjustments.tint, range: -100...100) { String(format: "%.0f", $0) }
                Toggle("Monochrome", isOn: $adjustments.monochrome)
                LabeledSlider(title: "Sepia", value: $adjustments.sepia, range: 0...1)
            }
            SidebarSection(title: "Detail") {
                LabeledSlider(title: "Sharpness", value: $adjustments.sharpness, range: 0...2)
                LabeledSlider(title: "Clarity", value: $adjustments.clarity, range: 0...1)
                LabeledSlider(title: "Dehaze", value: $adjustments.dehaze, range: 0...1)
                LabeledSlider(title: "Noise reduction", value: $adjustments.noiseReduction, range: 0...1)
            }
            SidebarSection(title: "Effects") {
                LabeledSlider(title: "Grain", value: $adjustments.grain, range: 0...1)
                LabeledSlider(title: "Vignette", value: $adjustments.vignette, range: 0...2)
            }
            Button("Reset all") { adjustments = PhotoAdjustments() }
                .buttonStyle(.link)
        }
        .onChange(of: adjustments) { _ in scheduleRender() }
        .onChange(of: document.preview) { _ in scheduleRender() }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let adjustments = adjustments
        renderTask = Task.detached(priority: .userInitiated) {
            let output = ImageOps.adjusted(CIImage(cgImage: cg), adjustments)
            guard !Task.isCancelled, let image = ImageToolSupport.cgImage(output) else { return }
            let ns = ImageOps.nsImage(image)
            await MainActor.run { rendered = ns }
        }
    }

    private func save() {
        guard let original = document.original else { return }
        let adjustments = adjustments
        ImageToolSupport.save(session, suffix: "edited") {
            let output = ImageOps.adjusted(CIImage(cgImage: original), adjustments)
            guard let image = ImageToolSupport.cgImage(output) else { throw SatsumaError.encodeFailed("Rendering failed") }
            return image
        }
    }
}
