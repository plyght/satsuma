import AppKit
import Combine
import SwiftUI

final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    @Published var progress: Double = 0
    @Published var status: Status = .waiting
    var outputs: [URL] = []

    enum Status: Equatable {
        case waiting
        case running
        case done
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .done, .failed: return true
            case .waiting, .running: return false
            }
        }
    }

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

@MainActor
final class JobRunner: ObservableObject {
    static let shared = JobRunner()

    @Published private(set) var jobs: [Job] = []
    private var hud: JobHUD?
    private var hudStyle: ProgressStyle?
    private var hideWorkItem: DispatchWorkItem?
    private let semaphore = AsyncSemaphore(limit: 2)

    private init() {}

    func convert(_ urls: [URL], to target: FileFormat) {
        DiagnosticLog.log("convert \(urls.map(\.lastPathComponent)) -> \(target.displayName)")
        var reserved = Set<String>()
        for url in urls {
            guard let source = FileFormat.detect(url) else {
                DiagnosticLog.log("skipping \(url.lastPathComponent): format not detected")
                continue
            }
            let directory = AppSettings.shared.outputLocation.directory(for: url)
            let destination = ConversionMatrix.outputURL(for: url, target: target, in: directory, existing: reserved)
            DiagnosticLog.log("destination \(destination.path)")
            reserved.insert(destination.lastPathComponent)
            let job = Job(title: "Converting to \(target.displayName)", detail: url.lastPathComponent)
            enqueue(job) { progress in
                let request = ConversionRequest(source: url, sourceFormat: source, target: target, destination: destination, progress: progress)
                try await Engines.convert(request)
                return [destination]
            }
        }
    }

    func enqueue(_ job: Job, work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        jobs.append(job)
        DiagnosticLog.log("enqueue \(job.title) / \(job.detail); jobs=\(jobs.count)")
        showHUD()
        DiagnosticLog.log("hud shown")
        Task {
            await semaphore.wait()
            DiagnosticLog.log("job running: \(job.detail)")
            job.status = .running
            let progress: (Double) -> Void = { value in
                Task { @MainActor in job.progress = value }
            }
            do {
                let outputs = try await work(progress)
                job.outputs = outputs
                job.progress = 1
                job.status = .done
                DiagnosticLog.log("job done: \(job.detail) -> \(outputs.map(\.lastPathComponent))")
                if AppSettings.shared.revealInFinder, !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            } catch {
                DiagnosticLog.log("job failed: \(job.detail): \(error)")
                job.status = .failed(error.localizedDescription)
            }
            await semaphore.signal()
            scheduleHide()
        }
    }

    func run(title: String, detail: String, work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        enqueue(Job(title: title, detail: detail), work: work)
    }

    private func showHUD() {
        hideWorkItem?.cancel()
        let style = AppSettings.shared.progressStyle
        DiagnosticLog.log("showHUD style=\(style.rawValue) existing=\(hud != nil)")
        if hud == nil || hudStyle != style {
            hud?.hide()
            hud = style == .card ? JobHUDPanel(runner: self) : JobPillPanel(runner: self)
            hudStyle = style
        }
        hud?.show()
    }

    private func scheduleHide() {
        guard jobs.allSatisfy({ $0.status.isFinished }) else { return }
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hud?.hide()
            self.jobs.removeAll()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
    }

    func dismiss(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        if jobs.isEmpty { hud?.hide() }
    }

    func dismissAll() {
        hideWorkItem?.cancel()
        jobs.removeAll()
        hud?.hide()
    }
}

actor AsyncSemaphore {
    private let limit: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func wait() async {
        if count < limit {
            count += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            count = max(0, count - 1)
        }
    }
}

@MainActor
protocol JobHUD: AnyObject {
    func show()
    func hide()
}

final class JobHUDPanel: NSPanel, NSWindowDelegate, JobHUD {
    private weak var runner: JobRunner?

    init(runner: JobRunner) {
        self.runner = runner
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100), styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        delegate = self
        DiagnosticLog.log("card panel created")
        let controller = NSHostingController(rootView: JobHUDView(runner: runner))
        controller.sizingOptions = []
        contentViewController = controller
        DiagnosticLog.log("card hosting controller attached")
    }

    override var canBecomeKey: Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        runner?.dismissAll()
        return false
    }

    func show() {
        guard let screen = NSScreen.main else {
            DiagnosticLog.log("card show: no main screen")
            return
        }
        let visible = screen.visibleFrame
        contentView?.layoutSubtreeIfNeeded()
        let size = (contentView?.fittingSize ?? frame.size).roundedUp
        DiagnosticLog.log("card show size=\(size) visible=\(visible)")
        setContentSize(size)
        setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
        makeKeyAndOrderFront(nil)
        DiagnosticLog.log("card ordered front")
    }

    func hide() { orderOut(nil) }
}

final class JobPillPanel: NSPanel, JobHUD {
    init(runner: JobRunner) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        DiagnosticLog.log("pill panel created")
        let controller = NSHostingController(rootView: JobPillView(runner: runner))
        controller.sizingOptions = []
        contentViewController = controller
        DiagnosticLog.log("pill hosting controller attached")
    }

    override var canBecomeKey: Bool { true }

    func show() {
        guard let screen = NSScreen.main, let content = contentView else {
            DiagnosticLog.log("pill show: no main screen or content view")
            return
        }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize.roundedUp
        let top = screen.visibleFrame.maxY
        DiagnosticLog.log("pill show size=\(size) screen=\(screen.frame) top=\(top)")
        setContentSize(size)
        setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: top - size.height - 2))
        makeKeyAndOrderFront(nil)
        DiagnosticLog.log("pill ordered front")
    }

    func hide() { orderOut(nil) }
}

private extension CGSize {
    var roundedUp: CGSize { CGSize(width: ceil(width), height: ceil(height)) }
}

struct JobPillView: View {
    @ObservedObject var runner: JobRunner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(failed ? .red : Theme.accent)
                .contentTransition(.symbolEffect(.replace))
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: 96)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .glassEffect(.regular, in: .capsule)
        .padding(4)
        .tint(Theme.accent)
        .environment(\.appearsActive, true)
        .animation(.default, value: fraction)
    }

    private var fraction: Double {
        let jobs = runner.jobs
        guard !jobs.isEmpty else { return 0 }
        let total = jobs.reduce(0.0) { $0 + ($1.status == .done ? 1 : min(max($1.progress, 0), 1)) }
        return total / Double(jobs.count)
    }

    private var failed: Bool {
        runner.jobs.contains { if case .failed = $0.status { return true } else { return false } }
    }

    private var symbol: String {
        if failed { return "exclamationmark.triangle.fill" }
        return runner.jobs.allSatisfy { $0.status.isFinished } ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
    }
}

struct JobHUDView: View {
    @ObservedObject var runner: JobRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(runner.jobs.enumerated()), id: \.element.id) { index, job in
                if index > 0 { Divider() }
                JobCardView(job: job)
            }
        }
        .padding(.top, 12)
        .padding(.leading, 40)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .frame(width: 340)
        .background { Color.clear.glassEffect(.regular, in: .rect).ignoresSafeArea() }
        .tint(Theme.accent)
    }
}

struct JobCardView: View {
    @ObservedObject var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(job.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing
            }
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
    }

    private var fraction: CGFloat {
        job.status == .done ? 1 : CGFloat(min(max(job.progress, 0), 1))
    }

    private var subtitle: String {
        switch job.status {
        case .waiting: return "\(job.detail) · Waiting"
        case .running: return "\(job.detail) · \(Int((job.progress * 100).rounded()))%"
        case .done: return "\(job.detail) · Done"
        case .failed(let message): return "\(job.detail) · \(message)"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .waiting, .running:
            EmptyView()
        }
    }
}
