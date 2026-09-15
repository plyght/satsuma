import CoreImage
import SwiftUI

@MainActor
struct RedactImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var rects: [RectangleOverlay] = []
    @State private var selected: UUID?
    @State private var styles: [UUID: RedactionStyle] = [:]
    @State private var defaultStyle: RedactionStyle = .solid
    @State private var color = Color.black
    @State private var showPreview = false
    @State private var rendered: NSImage?
    @State private var renderTask: Task<Void, Never>?

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 2000))
    }

    private var redactions: [Redaction] {
        rects.map { overlay in
            var r = Redaction(rect: overlay.rect)
            r.style = styles[overlay.id] ?? defaultStyle
            r.color = color.nsColor.cgColor
            return r
        }
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: !rects.isEmpty, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    if showPreview, let rendered {
                        GeometryReader { proxy in
                            let fit = FitGeometry(container: proxy.size, image: document.size)
                            Image(nsImage: rendered).resizable().interpolation(.high)
                                .frame(width: fit.displayRect.width, height: fit.displayRect.height)
                                .offset(x: fit.displayRect.minX, y: fit.displayRect.minY)
                        }
                        .padding(12)
                    } else {
                        RectangleEditorCanvas(image: preview, imageSize: document.size, rectangles: $rects, selected: $selected, allowMultiple: true)
                            .padding(12)
                    }
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Redaction style") {
                Picker("", selection: styleBinding) {
                    ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if (selected.flatMap { styles[$0] } ?? defaultStyle) == .solid {
                    ColorSwatchPicker(title: "Color", color: $color)
                }
                Text(selected == nil ? "Applies to new areas." : "Applies to the selected area.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Areas (\(rects.count))") {
                if rects.isEmpty {
                    Text("Drag on the photo to cover an area. Drag areas to move them and their corners to resize.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(rects) { overlay in
                    HStack {
                        Circle().fill(overlay.id == selected ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        Text("Area \(overlay.label)").font(.callout)
                        Text((styles[overlay.id] ?? defaultStyle).title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { remove(overlay.id) } label: { Icon(.trash, size: 13) }.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = overlay.id }
                }
                if !rects.isEmpty {
                    Button("Remove all") { rects.removeAll(); styles.removeAll(); selected = nil }.controlSize(.small)
                }
            }
            SidebarSection(title: "Preview") {
                Toggle("Show result", isOn: $showPreview)
            }
        }
        .onChange(of: rects) { _ in relabel(); scheduleRender() }
        .onChange(of: styles) { _ in scheduleRender() }
        .onChange(of: color) { _ in scheduleRender() }
        .onChange(of: defaultStyle) { _ in scheduleRender() }
        .onChange(of: showPreview) { _ in scheduleRender() }
        .onDeleteCommand { if let selected { remove(selected) } }
    }

    private var styleBinding: Binding<RedactionStyle> {
        Binding(
            get: { selected.flatMap { styles[$0] } ?? defaultStyle },
            set: { new in
                if let selected { styles[selected] = new } else { defaultStyle = new }
                scheduleRender()
            }
        )
    }

    private func remove(_ id: UUID) {
        rects.removeAll { $0.id == id }
        styles.removeValue(forKey: id)
        if selected == id { selected = nil }
    }

    private func relabel() {
        for index in rects.indices where rects[index].label != "\(index + 1)" {
            rects[index].label = "\(index + 1)"
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard showPreview, let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil), document.size.width > 0 else { return }
        let scale = CGFloat(cg.width) / document.size.width
        let scaled = redactions.map { r -> Redaction in
            var copy = r
            copy.rect = r.rect.applying(CGAffineTransform(scaleX: scale, y: scale))
            return copy
        }
        renderTask = Task.detached(priority: .userInitiated) {
            let output = ImageOps.redact(CIImage(cgImage: cg), redactions: scaled)
            guard !Task.isCancelled, let image = ImageToolSupport.cgImage(output) else { return }
            let ns = ImageOps.nsImage(image)
            await MainActor.run { rendered = ns }
        }
    }

    private func save() {
        guard let original = document.original else { return }
        let redactions = redactions
        ImageToolSupport.save(session, suffix: "redacted") {
            let output = ImageOps.redact(CIImage(cgImage: original), redactions: redactions)
            guard let image = ImageToolSupport.cgImage(output) else { throw SatsumaError.encodeFailed("Rendering failed") }
            return image
        }
    }
}
