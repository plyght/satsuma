import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OrderedFileList: View {
    @Binding var files: [URL]
    var thumbnails: [URL: NSImage] = [:]
    var allowedTypes: [UTType] = [.image]
    var addTitle = "Add images…"

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(files.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        if let thumb = thumbnails[url] {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
                        }
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(FileSizeFormatter.string(FileSizeFormatter.size(of: url))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.disabled(index == files.count - 1)
                        Button { files.remove(at: index) } label: { Image(systemName: "xmark.circle") }.disabled(files.count <= 1)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
                .onMove { from, to in files.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button(addTitle) { add() }
                Button("Sort by name") { files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
                Spacer()
                Text("Drag rows to reorder").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !files.contains(url) { files.append(url) }
    }
}

@MainActor
final class ThumbnailCache: ObservableObject {
    @Published var images: [URL: NSImage] = [:]

    func load(_ urls: [URL], maxPixels: Int = 320) {
        for url in urls where images[url] == nil {
            Task.detached { [url] in
                guard let cg = try? ImageIOBridge.load(url, maxPixelSize: maxPixels) else { return }
                let ns = ImageOps.nsImage(cg)
                await MainActor.run { self.images[url] = ns }
            }
        }
    }
}

@MainActor
struct CreatePDFToolView: View {
    let session: ToolSession
    @State private var files: [URL]
    @StateObject private var thumbs = ThumbnailCache()
    @State private var pageMode: PageMode = .fitImage

    enum PageMode: String, CaseIterable, Identifiable {
        case fitImage, letter, a4
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fitImage: return "Page per image size"
            case .letter: return "US Letter"
            case .a4: return "A4"
            }
        }
        var size: CGSize? {
            switch self {
            case .fitImage: return nil
            case .letter: return CGSize(width: 612, height: 792)
            case .a4: return CGSize(width: 595, height: 842)
            }
        }
    }

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Create PDF", saveEnabled: !files.isEmpty, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs.images)
        } sidebar: {
            SidebarSection(title: "Pages") {
                Picker("", selection: $pageMode) {
                    ForEach(PageMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Text("One page per image, in list order. HEIC, WebP, SVG and other formats are rasterized as needed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Summary") {
                Text("\(files.count) page\(files.count == 1 ? "" : "s")").font(.callout)
            }
        }
        .onAppear { thumbs.load(files) }
        .onChange(of: files) { thumbs.load($0) }
    }

    private func save() {
        let files = files
        let pageSize = pageMode.size
        let destination = session.outputURL(suffix: files.count > 1 ? "combined" : "", ext: "pdf")
        session.run(title: "Create PDF") { progress in
            if let pageSize {
                try PDFRenderer.writeImagesPDF(files, pageSize: pageSize, to: destination, progress: progress)
            } else {
                try PDFOps.fromImages(files, to: destination, progress: progress)
            }
            return [destination]
        }
    }
}

@MainActor
struct CollageToolView: View {
    let session: ToolSession
    @State private var files: [URL]
    @StateObject private var thumbs = ThumbnailCache()
    @State private var layout: ImageOps.CollageLayout = .grid
    @State private var width = 2400
    @State private var height = 2400
    @State private var spacing: Double = 24
    @State private var corner: Double = 16
    @State private var background = Color.white
    @State private var preview: NSImage?
    @State private var renderTask: Task<Void, Never>?

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    private var options: ImageOps.CollageOptions {
        var o = ImageOps.CollageOptions()
        o.layout = layout
        o.width = CGFloat(max(64, width))
        o.height = CGFloat(max(64, height))
        o.spacing = spacing
        o.cornerRadius = corner
        o.background = background.nsColor
        return o
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save collage", saveEnabled: files.count >= 2, onSave: save) {
            HSplitView {
                OrderedFileList(files: $files, thumbnails: thumbs.images)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                ZStack {
                    CheckerboardBackground()
                    if let preview {
                        Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(16)
                    } else {
                        ProgressView()
                    }
                }
                .frame(minWidth: 320)
            }
        } sidebar: {
            SidebarSection(title: "Layout") {
                Picker("", selection: $layout) {
                    ForEach(ImageOps.CollageLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Final size") {
                NumberField(title: "Width", value: $width, suffix: "px")
                NumberField(title: "Height", value: $height, suffix: "px")
                HStack {
                    Button("Square") { width = 2400; height = 2400 }
                    Button("Landscape") { width = 3000; height = 2000 }
                    Button("Portrait") { width = 2000; height = 3000 }
                }
                .controlSize(.mini)
            }
            SidebarSection(title: "Style") {
                LabeledSlider(title: "Spacing", value: $spacing, range: 0...200) { String(format: "%.0f px", $0) }
                LabeledSlider(title: "Corner radius", value: $corner, range: 0...200) { String(format: "%.0f px", $0) }
                ColorSwatchPicker(title: "Background", color: $background)
            }
        }
        .onAppear { thumbs.load(files, maxPixels: 600); render() }
        .onChange(of: files) { thumbs.load($0, maxPixels: 600); render() }
        .onChange(of: thumbs.images.count) { _ in render() }
        .onChange(of: layout) { _ in render() }
        .onChange(of: width) { _ in render() }
        .onChange(of: height) { _ in render() }
        .onChange(of: spacing) { _ in render() }
        .onChange(of: corner) { _ in render() }
        .onChange(of: background) { _ in render() }
    }

    private func render() {
        renderTask?.cancel()
        let images = files.compactMap { thumbs.images[$0]?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard !images.isEmpty else { return }
        var scaled = options
        let scale = min(1, 1200 / max(scaled.width, scaled.height))
        scaled.width *= scale
        scaled.height *= scale
        scaled.spacing *= scale
        scaled.cornerRadius *= scale
        let o = scaled
        renderTask = Task.detached(priority: .userInitiated) {
            guard let cg = ImageOps.collage(images, options: o), !Task.isCancelled else { return }
            let ns = ImageOps.nsImage(cg)
            await MainActor.run { preview = ns }
        }
    }

    private func save() {
        let files = files
        let o = options
        ImageToolSupport.save(session, suffix: "collage", format: .jpg, title: "Create collage") {
            let images = try files.map { try ImageIOBridge.load($0, maxPixelSize: 4000) }
            guard let cg = ImageOps.collage(images, options: o) else { throw SatsumaError.encodeFailed("Collage rendering failed") }
            return cg
        }
    }
}
