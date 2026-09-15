import AppKit
import SwiftUI

struct ResizeImageToolView: View {
    let session: ToolSession
    @State private var mode: Mode = .longEdge
    @State private var longEdge = 1920
    @State private var percent = 50
    @State private var width = 0
    @State private var height = 0
    @State private var lockAspect = true
    @State private var sizes: [URL: CGSize] = [:]

    enum Mode: String, CaseIterable, Identifiable {
        case longEdge, percent, exact
        var id: String { rawValue }
        var title: String {
            switch self {
            case .longEdge: return "Long edge"
            case .percent: return "Percent"
            case .exact: return "Exact"
            }
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Resize" : "Resize \(session.files.count) images", onSave: save) {
            List(session.files, id: \.self) { url in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent).lineLimit(1)
                        if let size = sizes[url] {
                            let target = targetSize(for: size)
                            Text("\(Int(size.width)) × \(Int(size.height))  →  \(Int(target.width)) × \(Int(target.height))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        } sidebar: {
            SidebarSection(title: "Resize by") {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch mode {
                case .longEdge:
                    NumberField(title: "Long edge", value: $longEdge, suffix: "px")
                    HStack {
                        ForEach([640, 1080, 1920, 2560, 4096], id: \.self) { value in
                            Button("\(value)") { longEdge = value }.controlSize(.mini)
                        }
                    }
                case .percent:
                    NumberField(title: "Scale", value: $percent, suffix: "%")
                case .exact:
                    NumberField(title: "Width", value: $width, suffix: "px")
                    NumberField(title: "Height", value: $height, suffix: "px")
                    Toggle("Keep aspect ratio (fit inside)", isOn: $lockAspect)
                }
            }
            SidebarSection(title: "Notes") {
                Text("Images are never enlarged beyond the requested size with the long-edge mode. Output keeps the original format where it can be written natively.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            for url in session.files { sizes[url] = ImageIOBridge.pixelSize(url) }
            if let first = sizes[session.primary] { width = Int(first.width); height = Int(first.height) }
        }
    }

    private func targetSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        switch mode {
        case .longEdge:
            let scale = min(1, CGFloat(max(1, longEdge)) / max(size.width, size.height))
            return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        case .percent:
            let scale = CGFloat(max(1, percent)) / 100
            return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        case .exact:
            let w = CGFloat(max(1, width)), h = CGFloat(max(1, height))
            if lockAspect {
                let scale = min(w / size.width, h / size.height)
                return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            }
            return CGSize(width: w, height: h)
        }
    }

    private func save() {
        let mode = mode, longEdge = longEdge, percent = percent, width = width, height = height, lockAspect = lockAspect
        ImageToolSupport.saveEach(session, suffix: "resized", title: "Resize \(session.files.count) image\(session.files.count == 1 ? "" : "s")") { _, image in
            let size = CGSize(width: image.width, height: image.height)
            let target: CGSize
            switch mode {
            case .longEdge:
                let scale = min(1, CGFloat(max(1, longEdge)) / max(size.width, size.height))
                target = CGSize(width: size.width * scale, height: size.height * scale)
            case .percent:
                let scale = CGFloat(max(1, percent)) / 100
                target = CGSize(width: size.width * scale, height: size.height * scale)
            case .exact:
                let w = CGFloat(max(1, width)), h = CGFloat(max(1, height))
                if lockAspect {
                    let scale = min(w / size.width, h / size.height)
                    target = CGSize(width: size.width * scale, height: size.height * scale)
                } else {
                    target = CGSize(width: w, height: h)
                }
            }
            return ImageIOBridge.scaled(image, to: CGSize(width: max(1, target.width.rounded()), height: max(1, target.height.rounded())))
        }
    }
}

struct RotateImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var quarterTurns = 0
    @State private var flipH = false
    @State private var flipV = false

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1600))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Save copy" : "Apply to \(session.files.count) images", saveEnabled: document.preview != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    Image(nsImage: preview)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(quarterTurns) * 90))
                        .scaleEffect(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
                        .padding(40)
                        .animation(.easeInOut(duration: 0.18), value: quarterTurns)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Rotate") {
                HStack {
                    Button { quarterTurns = (quarterTurns + 3) % 4 } label: { Label("Left", systemImage: "rotate.left") }
                    Button { quarterTurns = (quarterTurns + 1) % 4 } label: { Label("Right", systemImage: "rotate.right") }
                }
                Text("\(quarterTurns * 90)°").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Flip") {
                Toggle("Flip horizontally", isOn: $flipH)
                Toggle("Flip vertically", isOn: $flipV)
            }
            if session.files.count > 1 {
                SidebarSection(title: "Batch") {
                    Text("The same rotation and flips are applied to all \(session.files.count) images.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() {
        let turns = quarterTurns, h = flipH, v = flipV
        ImageToolSupport.saveEach(session, suffix: "rotated", title: "Rotate \(session.files.count) image\(session.files.count == 1 ? "" : "s")") { _, image in
            ImageOps.rotated(image, quarterTurns: turns, flipHorizontal: h, flipVertical: v)
        }
    }
}
