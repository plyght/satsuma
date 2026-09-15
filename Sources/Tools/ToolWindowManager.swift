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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
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

struct WindowChrome<Content: View>: View {
    let session: ToolSession
    var saveTitle: String
    var saveEnabled: Bool
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content

    private var fileLabel: String {
        session.files.count == 1 ? session.primary.lastPathComponent : "\(session.files.count) files"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(session.tool.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                HStack {
                    Button { ToolWindowManager.shared.close(session) } label: { Icon(.x, size: 14) }
                        .buttonStyle(CircleIconButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .help("Close")
                    Spacer()
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 60)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Icon(session.tool.icon, size: 16)
                    .foregroundStyle(Theme.inkSecondary)
                Text(fileLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Button("Cancel") { ToolWindowManager.shared.close(session) }
                    .buttonStyle(QuietButtonStyle())
                Button(saveTitle) { onSave() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!saveEnabled)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(WindowBackground())
        .preferredColorScheme(.light)
    }
}

struct WindowBackground: View {
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(Color.white.opacity(0.55)), in: RoundedRectangle(cornerRadius: Theme.windowCorner, style: .continuous))
                .ignoresSafeArea()
        } else {
            legacy
        }
        #else
        legacy
        #endif
    }

    private var legacy: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Color(nsColor: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 0.86))
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.windowCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.windowCorner, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
        }
        .ignoresSafeArea()
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
        WindowChrome(session: session, saveTitle: saveTitle, saveEnabled: saveEnabled, onSave: onSave) {
            HStack(spacing: 14) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sidebar()
                    }
                    .padding(.trailing, 2)
                }
                .frame(width: 292)
            }
            .padding(18)
        }
    }
}

struct FormShell<Content: View>: View {
    let session: ToolSession
    var saveTitle = "Save copy"
    var saveEnabled = true
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        WindowChrome(session: session, saveTitle: saveTitle, saveEnabled: saveEnabled, onSave: onSave) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.ink)
            content()
            Spacer(minLength: 0)
        }
    }
}

struct FormHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(Theme.ink)
    }
}

struct FormHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.inkSecondary)
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
