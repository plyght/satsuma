import AppKit
import SwiftUI

struct ToolSession: Identifiable {
    let id = UUID()
    let tool: ToolID
    let files: [URL]

    var formats: [FileFormat] { files.compactMap(FileFormat.detect) }
    var primary: URL { files[0] }
    var primaryFormat: FileFormat { FileFormat.detect(primary) ?? .png }
    var baseName: String { ConversionMatrix.strippedBaseName(primary.lastPathComponent) }
    var outputDirectory: URL { AppSettings.shared.outputLocation.directory(for: primary) }

    func outputURL(suffix: String, ext: String, baseName: String? = nil) -> URL {
        ConversionMatrix.uniqueURL(directory: outputDirectory, baseName: baseName ?? self.baseName, suffix: suffix, ext: ext)
    }
}

@MainActor
final class ToolWindowManager: NSObject, NSWindowDelegate {
    static let shared = ToolWindowManager()

    private var windows: [UUID: NSWindow] = [:]

    var openWindows: [NSWindow] { Array(windows.values) }

    func closeAll() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }

    func open(_ tool: ToolID, files: [URL]) {
        guard !files.isEmpty else { return }
        let session = ToolSession(tool: tool, files: files)
        let root = ToolRootView(session: session)
            .environmentObject(AppSettings.shared)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "\(tool.title) — \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.preferredSize(for: tool))
        window.minSize = NSSize(width: 560, height: 420)
        window.center()
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(session.id.uuidString)
        windows[session.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ session: ToolSession) {
        windows[session.id]?.close()
        windows.removeValue(forKey: session.id)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue, let uuid = UUID(uuidString: id) else { return }
        windows.removeValue(forKey: uuid)
    }

    static func preferredSize(for tool: ToolID) -> NSSize {
        switch tool {
        case .compress, .editMetadata, .resizeImage, .rotateImage, .createPDF, .mergePDF, .splitPDF, .audioChannels, .normalizeAudio:
            return NSSize(width: 640, height: 520)
        case .organizePDF, .createCollage, .joinVideos:
            return NSSize(width: 900, height: 640)
        default:
            return NSSize(width: 960, height: 680)
        }
    }
}

struct ToolRootView: View {
    let session: ToolSession

    var body: some View {
        Group {
            switch session.tool {
            case .compress: CompressToolView(session: session)
            case .editMetadata: MetadataToolView(session: session)
            case .editImage: EditImageToolView(session: session)
            case .frameImage: FrameImageToolView(session: session)
            case .cropImage: CropImageToolView(session: session)
            case .redactImage: RedactImageToolView(session: session)
            case .resizeImage: ResizeImageToolView(session: session)
            case .rotateImage: RotateImageToolView(session: session)
            case .createPDF: CreatePDFToolView(session: session)
            case .createCollage: CollageToolView(session: session)
            case .trimVideo: TrimVideoToolView(session: session)
            case .cropVideo: CropVideoToolView(session: session)
            case .changeVideoSpeed: VideoSpeedToolView(session: session)
            case .joinVideos: JoinVideosToolView(session: session)
            case .videoSnapshots: VideoSnapshotsToolView(session: session)
            case .splitVideo: SplitVideoToolView(session: session)
            case .redactVideo: RedactVideoToolView(session: session)
            case .normalizeAudio: NormalizeAudioToolView(session: session)
            case .audioToVideo: AudioToVideoToolView(session: session)
            case .trimAudio: TrimAudioToolView(session: session)
            case .audioChannels: AudioChannelsToolView(session: session)
            case .redactAudio: RedactAudioToolView(session: session)
            case .mergePDF: MergePDFToolView(session: session)
            case .organizePDF: OrganizePDFToolView(session: session)
            case .splitPDF: SplitPDFToolView(session: session)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

struct ToolShell<Content: View, Sidebar: View>: View {
    let session: ToolSession
    var saveTitle = "Save copy"
    var saveEnabled = true
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var sidebar: () -> Sidebar

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sidebar()
                    }
                    .padding(16)
                }
                .frame(width: 300)
            }
            Divider()
            HStack {
                Label {
                    Text(session.files.count == 1 ? session.primary.lastPathComponent : "\(session.files.count) files")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: session.tool.symbol)
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                Spacer()
                Button("Cancel") { ToolWindowManager.shared.close(session) }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!saveEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Int
    var suffix = ""

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary).font(.callout) }
        }
    }
}

struct TimecodeField: View {
    let title: String
    @Binding var seconds: Double
    var maximum: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            TextField("0:00.00", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { isFocused in if !isFocused { commit() } }
        }
        .onAppear { text = TimeFormatter.clock(seconds) }
        .onChange(of: seconds) { newValue in if !focused { text = TimeFormatter.clock(newValue) } }
    }

    private func commit() {
        if let parsed = TimeFormatter.parseClock(text) {
            seconds = min(max(0, parsed), maximum)
        }
        text = TimeFormatter.clock(seconds)
    }
}

extension ToolSession {
    @MainActor
    func run(title: String, work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        ToolWindowManager.shared.close(self)
        JobRunner.shared.run(title: title, work: work)
    }
}
