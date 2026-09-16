import AppKit
import Combine
import SwiftUI
import UserNotifications

final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
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

    init(title: String) { self.title = title }
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
            let job = Job(title: "\(url.lastPathComponent) → \(target.displayName)")
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

    func run(title: String, work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        enqueue(Job(title: title), work: work)
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
        content.body = job.outputs.count == 1 ? job.outputs[0].lastPathComponent : "\(job.title): \(job.outputs.count) files"
        content.sound = .default
        deliver(content)
    }

    static func failed(_ job: Job, error: Error) {
        guard AppSettings.shared.showNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Satsuma couldn't finish"
        content.body = "\(job.title): \(error.localizedDescription)"
        deliver(content)
    }

    private static func deliver(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

final class JobHUDPanel: NSPanel {
    init(runner: JobRunner) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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
        let size = contentView?.fittingSize ?? NSSize(width: 320, height: 120)
        setContentSize(size)
        setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.minY + 20))
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

struct JobHUDView: View {
    @ObservedObject var runner: JobRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(runner.jobs) { job in
                JobRowView(job: job) { runner.dismiss(job) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct JobRowView: View {
    @ObservedObject var job: Job
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch job.status {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                default:
                    ProgressView().controlSize(.small)
                }
            }
            if case .failed(let message) = job.status {
                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            } else {
                ProgressView(value: job.status == .done ? 1 : job.progress).progressViewStyle(.linear)
            }
        }
    }
}
