import AppKit
import SwiftUI

struct CropImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var rects: [RectangleOverlay] = []
    @State private var selected: UUID?
    @State private var aspect = AspectPreset.all[0]
    @State private var width = 0
    @State private var height = 0

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary))
    }

    private var cropRect: CGRect? { rects.first?.rect }

    private var aspectRatio: CGFloat? {
        guard let ratio = aspect.ratio else { return nil }
        if ratio < 0, document.size.height > 0 { return document.size.width / document.size.height }
        return ratio
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: cropRect.map { $0.width >= 1 && $0.height >= 1 } ?? false, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    RectangleEditorCanvas(image: preview, imageSize: document.size, rectangles: $rects, selected: $selected, allowMultiple: false, aspect: aspectRatio)
                        .padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Aspect ratio") {
                Picker("", selection: $aspect) {
                    ForEach(AspectPreset.all) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            SidebarSection(title: "Dimensions") {
                NumberField(title: "Width", value: $width, suffix: "px")
                NumberField(title: "Height", value: $height, suffix: "px")
                Text("Original: \(Int(document.size.width)) × \(Int(document.size.height))").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Center") { centerCrop() }
                    Button("Whole image") { setCrop(CGRect(origin: .zero, size: document.size)) }
                }
                .controlSize(.small)
            }
            SidebarSection(title: "How to") {
                Text("Drag on the photo to draw the crop. Drag the corners to resize, or type pixel dimensions. The copy is saved at full resolution.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: rects) { new in
            guard let rect = new.first?.rect else { return }
            let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
            if w != width { width = w }
            if h != height { height = h }
        }
        .onChange(of: width) { _ in applyDimensions() }
        .onChange(of: height) { _ in applyDimensions() }
        .onChange(of: aspect) { _ in applyAspect() }
        .onChange(of: document.preview) { _ in
            if rects.isEmpty { setCrop(CGRect(origin: .zero, size: document.size).insetBy(dx: document.size.width * 0.1, dy: document.size.height * 0.1)) }
        }
    }

    private func setCrop(_ rect: CGRect) {
        let clamped = rect.intersection(CGRect(origin: .zero, size: document.size)).integral
        if let first = rects.first {
            rects = [RectangleOverlay(id: first.id, rect: clamped, color: .orange, label: "")]
        } else {
            let id = UUID()
            rects = [RectangleOverlay(id: id, rect: clamped, color: .orange, label: "")]
            selected = id
        }
    }

    private func applyDimensions() {
        guard let rect = cropRect, width > 0, height > 0 else { return }
        if Int(rect.width.rounded()) == width, Int(rect.height.rounded()) == height { return }
        var new = CGRect(x: rect.minX, y: rect.minY, width: CGFloat(width), height: CGFloat(height))
        new.origin.x = min(new.minX, max(0, document.size.width - new.width))
        new.origin.y = min(new.minY, max(0, document.size.height - new.height))
        setCrop(new)
    }

    private func applyAspect() {
        guard let ratio = aspectRatio, let rect = cropRect else { return }
        var new = rect
        new.size.height = rect.width / ratio
        if new.maxY > document.size.height {
            new.size.height = document.size.height - rect.minY
            new.size.width = new.height * ratio
        }
        setCrop(new)
    }

    private func centerCrop() {
        guard let rect = cropRect else { return }
        setCrop(CGRect(x: (document.size.width - rect.width) / 2, y: (document.size.height - rect.height) / 2, width: rect.width, height: rect.height))
    }

    private func save() {
        guard let original = document.original, let rect = cropRect else { return }
        ImageToolSupport.save(session, suffix: "cropped") {
            ImageIOBridge.cropped(original, to: rect.integral)
        }
    }
}

extension RectangleOverlay: Equatable {
    static func == (lhs: RectangleOverlay, rhs: RectangleOverlay) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.label == rhs.label
    }
}
