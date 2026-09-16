import AppKit
import Combine
import SwiftUI
import UserNotifications

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
    private var hud: JobHUDPanel?
    private var hideWorkItem: DispatchWorkItem?
    private let semaphore = AsyncSemaphore(limit: 2)

    private init() {}

    func convert(_ urls: [URL], to target: FileFormat) {
        var reserved = Set<String>()
        for url in urls {
            guard let source = FileFormat.detect(url) else { continue }
            let directory = AppSettings.shared.outputLocation.directory(for: url)
            let destination = ConversionMatrix.outputURL(for: url, target: target, in: directory, existing: reserved)
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
        showHUD()
        Task {
            await semaphore.wait()
            job.status = .running
            let progress: (Double) -> Void = { value in
                Task { @MainActor in job.progress = value }
            }
            do {
                let outputs = try await work(progress)
                job.outputs = outputs
                job.progress = 1
                job.status = .done
                Notifier.completed(job)
                if AppSettings.shared.revealInFinder, !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            } catch {
                job.status = .failed(error.localizedDescription)
                Notifier.failed(job, error: error)
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
        if hud == nil { hud = JobHUDPanel(runner: self) }
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

enum Notifier {
    static func completed(_ job: Job) {
        guard AppSettings.shared.showNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Satsuma finished"
        content.body = job.outputs.count == 1 ? job.outputs[0].lastPathComponent : "\(job.detail): \(job.outputs.count) files"
        content.sound = .default
        deliver(content)
    }

    static func failed(_ job: Job, error: Error) {
        guard AppSettings.shared.showNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Satsuma couldn't finish"
        content.body = "\(job.detail): \(error.localizedDescription)"
        deliver(content)
    }

    private static func deliver(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

final class JobHUDPanel: NSPanel {
    init(runner: JobRunner) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100), styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: JobHUDView(runner: runner))
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? NSSize(width: 340, height: 100)
        setContentSize(size)
        setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

struct JobHUDView: View {
    @ObservedObject var runner: JobRunner

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                ForEach(runner.jobs) { job in
                    JobCardView(job: job) { runner.dismiss(job) }
                }
            }
        }
        .padding(12)
        .frame(width: 340)
        .tint(Theme.accent)
    }
}

struct JobCardView: View {
    @ObservedObject var job: Job
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Dismiss")
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
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(6, proxy.size.width * fraction))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                }
            }
            .frame(height: 5)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
