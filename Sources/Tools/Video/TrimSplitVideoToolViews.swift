import AVFoundation
import SwiftUI

@MainActor
struct TrimVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var start: Double = 0
    @State private var end: Double = 0

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Trim", saveEnabled: end > start, onSave: save) {
            VStack(spacing: 10) {
                PlayerSurface(player: media.player)
                    .background(Color.black)
                TransportBar(controller: media)
                RangeTrack(duration: media.duration, start: $start, end: $end, playhead: media.currentTime, onScrub: { media.seek($0) })
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Range") {
                TimecodeField(title: "Start", seconds: $start, maximum: media.duration)
                TimecodeField(title: "End", seconds: $end, maximum: media.duration)
                HStack {
                    Button("Set start to playhead") { start = min(media.currentTime, end - 0.05) }
                    Button("Set end") { end = max(media.currentTime, start + 0.05) }
                }
                .controlSize(.small)
                Text("Length: \(TimeFormatter.clock(max(0, end - start)))").font(.callout.monospacedDigit())
            }
            SidebarSection(title: "Preview") {
                Button("Play selection") { media.playRange(start, end) }
                Text("Use the frame buttons or ← → to step frame by frame while the video is paused.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Output") {
                Text("The selection is copied without re-encoding when the format allows it, so the trim is fast and lossless.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.duration) { duration in if end == 0 { end = duration } }
        .onChange(of: start) { new in if abs(media.currentTime - new) > 0.01 { media.seek(new) } }
        .onChange(of: end) { new in media.seek(new) }
        .background(KeyCaptureView { key in
            switch key {
            case .left: media.stepFrame(-1)
            case .right: media.stepFrame(1)
            case .space: media.togglePlay()
            }
        })
    }

    private func save() {
        let url = session.primary, start = start, end = end
        let destination = session.outputURL(suffix: "trimmed", ext: url.pathExtension)
        session.run(title: "Trim \(url.lastPathComponent)") { progress in
            try await VideoOps.trim(url, start: start, end: end, to: destination, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct SplitVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var mode: Mode = .points
    @State private var points: [Double] = []
    @State private var parts = 2
    @State private var unusedStart: Double = 0
    @State private var unusedEnd: Double = 0

    enum Mode: String, CaseIterable, Identifiable {
        case points, equal
        var id: String { rawValue }
        var title: String { self == .points ? "Custom points" : "Equal parts" }
    }

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var effectivePoints: [Double] {
        switch mode {
        case .points: return points.sorted()
        case .equal:
            guard parts > 1, media.duration > 0 else { return [] }
            return (1..<parts).map { media.duration * Double($0) / Double(parts) }
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Split into \(effectivePoints.count + 1) clips", saveEnabled: !effectivePoints.isEmpty, onSave: save) {
            VStack(spacing: 10) {
                PlayerSurface(player: media.player).background(Color.black)
                TransportBar(controller: media)
                RangeTrack(duration: media.duration, start: $unusedStart, end: $unusedEnd, playhead: media.currentTime, markers: effectivePoints, onScrub: { media.seek($0) })
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Split") {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch mode {
                case .points:
                    Button("Add split at playhead") {
                        let t = media.currentTime
                        if t > 0.1, t < media.duration - 0.1, !points.contains(where: { abs($0 - t) < 0.05 }) { points.append(t) }
                    }
                    ForEach(points.sorted(), id: \.self) { point in
                        HStack {
                            Text(TimeFormatter.clock(point)).font(.callout.monospacedDigit())
                            Spacer()
                            Button { media.seek(point) } label: { Icon(.forwardStep, size: 13) }
                            Button { points.removeAll { $0 == point } } label: { Icon(.trash, size: 13) }
                        }
                        .buttonStyle(.borderless)
                    }
                case .equal:
                    Stepper("Parts: \(parts)", value: $parts, in: 2...50)
                    Text("Each clip lasts about \(TimeFormatter.clock(media.duration / Double(parts))).").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Output") {
                Text("All clips are placed in one folder next to the original, numbered in order. Clips are copied without re-encoding when possible.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.duration) { unusedEnd = $0 }
    }

    private func save() {
        let url = session.primary
        let points = effectivePoints
        let duration = media.duration
        let folder = ConversionMatrix.uniqueDirectory(directory: session.outputDirectory, name: "\(session.baseName) clips")
        session.run(title: "Split \(url.lastPathComponent)") { progress in
            try await VideoOps.split(url, at: points, duration: duration, into: folder, progress: progress)
        }
    }
}

struct KeyCaptureView: NSViewRepresentable {
    enum Key { case left, right, space }
    let handler: (Key) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) { nsView.handler = handler }

    final class KeyView: NSView {
        var handler: ((Key) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true, !(self.window?.firstResponder is NSTextView) else { return event }
                switch event.keyCode {
                case 123: self.handler?(.left); return nil
                case 124: self.handler?(.right); return nil
                case 49: self.handler?(.space); return nil
                default: return event
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
