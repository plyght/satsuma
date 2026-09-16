import AVFoundation
import SwiftUI

@MainActor
struct VideoSnapshotsToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var frames: [Snapshot] = []
    @State private var format: FileFormat = .png
    @State private var intervalMode = false
    @State private var everySeconds: Double = 5

    struct Snapshot: Identifiable, Equatable {
        let id = UUID()
        let time: Double
        var thumbnail: NSImage?
        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool { lhs.id == rhs.id }
    }

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var plannedTimes: [Double] {
        if intervalMode {
            guard media.duration > 0, everySeconds > 0 else { return [] }
            return stride(from: 0, to: media.duration, by: everySeconds).map { $0 }
        }
        return frames.map(\.time).sorted()
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save \(plannedTimes.count) frame\(plannedTimes.count == 1 ? "" : "s")", saveEnabled: !plannedTimes.isEmpty, onSave: save) {
            VideoStage(player: media.player) {
                RangeTrack(duration: media.duration, start: .constant(0), end: .constant(0), playhead: media.currentTime, markers: plannedTimes, onScrub: { media.seek($0) })
                    .frame(height: 28)
                if !intervalMode {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(frames.sorted { $0.time < $1.time }) { snap in
                                VStack(spacing: 4) {
                                    ZStack(alignment: .topTrailing) {
                                        if let thumb = snap.thumbnail {
                                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).frame(height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                                        } else {
                                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2)).frame(width: 128, height: 72)
                                        }
                                        Button { frames.removeAll { $0.id == snap.id } } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.borderless).padding(3)
                                    }
                                    Text(TimeFormatter.clock(snap.time)).font(.caption2.monospacedDigit())
                                }
                                .onTapGesture { media.seek(snap.time) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 100)
                }
            }
        } sidebar: {
            SidebarSection(title: "Frames") {
                Toggle("Every N seconds", isOn: $intervalMode)
                if intervalMode {
                    LabeledSlider(title: "Interval", value: $everySeconds, range: 0.5...60) { String(format: "%.1f s", $0) }
                    Text("\(plannedTimes.count) frames").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Button("Add current frame") { addCurrent() }
                        .keyboardShortcut("f", modifiers: [])
                    Text("Step with ← → to pick exact frames, then press F or the button. \(frames.count) chosen.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Format") {
                Picker("", selection: $format) {
                    Text("PNG (lossless)").tag(FileFormat.png)
                    Text("JPG").tag(FileFormat.jpg)
                    Text("HEIC").tag(FileFormat.heic)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text("Frames are exported at full video resolution into one folder.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .background(KeyCaptureView { key in
            switch key {
            case .left: media.stepFrame(-1)
            case .right: media.stepFrame(1)
            case .space: media.togglePlay()
            }
        })
    }

    private func addCurrent() {
        let time = media.currentTime
        guard !frames.contains(where: { abs($0.time - time) < 0.001 }) else { return }
        let snap = Snapshot(time: time)
        frames.append(snap)
        let url = session.primary
        Task.detached {
            guard let cg = try? await VideoOps.snapshot(url, at: time) else { return }
            let ns = ImageOps.nsImage(ImageIOBridge.resized(cg, longEdge: 256))
            await MainActor.run {
                if let index = frames.firstIndex(where: { $0.id == snap.id }) { frames[index].thumbnail = ns }
            }
        }
    }

    private func save() {
        let url = session.primary
        let times = plannedTimes
        let format = format
        let quality = AppSettings.shared.jpegQuality
        let folder = ConversionMatrix.uniqueDirectory(directory: session.outputDirectory, name: "\(session.baseName) frames")
        session.run(title: "Saving", detail: "\(times.count) frames") { progress in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var outputs: [URL] = []
            for (index, time) in times.enumerated() {
                let image = try await VideoOps.snapshot(url, at: time)
                let name = TimeFormatter.clock(time, fractionDigits: 3).replacingOccurrences(of: ":", with: "-")
                let destination = folder.appendingPathComponent("frame \(String(format: "%03d", index + 1)) @ \(name).\(format.fileExtension)")
                try ImageIOBridge.write(image, to: destination, format: format, quality: quality)
                outputs.append(destination)
                progress(Double(index + 1) / Double(times.count))
            }
            return outputs
        }
    }
}

@MainActor
struct RedactVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var frame: NSImage?
    @State private var rects: [RectangleOverlay] = []
    @State private var selected: UUID?
    @State private var ranges: [UUID: ClosedRange<Double>] = [:]
    @State private var styles: [UUID: RedactionStyle] = [:]
    @State private var defaultStyle: RedactionStyle = .solid

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var videoSize: CGSize { media.info.naturalSize }

    private var selectedRange: Binding<ClosedRange<Double>> {
        Binding(
            get: { selected.flatMap { ranges[$0] } ?? 0...max(media.duration, 0.01) },
            set: { new in if let selected { ranges[selected] = new } }
        )
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Redact", saveEnabled: !rects.isEmpty, onSave: save) {
            VStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let frame {
                        RectangleEditorCanvas(image: frame, imageSize: videoSize, rectangles: $rects, selected: $selected, allowMultiple: true)
                    } else {
                        ProgressView()
                    }
                }
                TransportBar(controller: media)
                RangeTrack(
                    duration: media.duration,
                    start: Binding(get: { selectedRange.wrappedValue.lowerBound }, set: { new in updateRange(lower: new) }),
                    end: Binding(get: { selectedRange.wrappedValue.upperBound }, set: { new in updateRange(upper: new) }),
                    playhead: media.currentTime,
                    onScrub: { media.seek($0) }
                )
                .opacity(selected == nil ? 0.4 : 1)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Style") {
                Picker("", selection: styleBinding) {
                    ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: "Time range") {
                if let selected, let range = ranges[selected] {
                    TimecodeField(title: "From", seconds: Binding(get: { range.lowerBound }, set: { updateRange(lower: $0) }), maximum: media.duration)
                    TimecodeField(title: "To", seconds: Binding(get: { range.upperBound }, set: { updateRange(upper: $0) }), maximum: media.duration)
                    Button("Whole video") { ranges[selected] = 0...media.duration }.controlSize(.small)
                } else {
                    Text("Select an area to set when it is covered. New areas cover the whole video.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Areas (\(rects.count))") {
                if rects.isEmpty {
                    Text("Drag on the frame to add a redaction. Each area can have its own time range.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(rects) { overlay in
                    HStack {
                        Circle().fill(overlay.id == selected ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text("Area \(overlay.label) · \((styles[overlay.id] ?? defaultStyle).title)").font(.callout)
                            if let range = ranges[overlay.id] {
                                Text("\(TimeFormatter.clock(range.lowerBound)) – \(TimeFormatter.clock(range.upperBound))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { remove(overlay.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = overlay.id }
                }
            }
        }
        .onChange(of: media.currentTime) { _ in loadFrame() }
        .onChange(of: media.loaded) { if $0 { loadFrame() } }
        .onChange(of: rects) { new in
            for (index, overlay) in new.enumerated() {
                if ranges[overlay.id] == nil { ranges[overlay.id] = 0...max(media.duration, 0.01) }
                if rects[index].label != "\(index + 1)" { rects[index].label = "\(index + 1)" }
            }
        }
        .onDeleteCommand { if let selected { remove(selected) } }
    }

    private var styleBinding: Binding<RedactionStyle> {
        Binding(
            get: { selected.flatMap { styles[$0] } ?? defaultStyle },
            set: { new in if let selected { styles[selected] = new } else { defaultStyle = new } }
        )
    }

    private func updateRange(lower: Double? = nil, upper: Double? = nil) {
        guard let selected else { return }
        let current = ranges[selected] ?? 0...media.duration
        let low = min(lower ?? current.lowerBound, current.upperBound - 0.01)
        let high = max(upper ?? current.upperBound, low + 0.01)
        ranges[selected] = max(0, low)...min(media.duration, high)
    }

    private func remove(_ id: UUID) {
        rects.removeAll { $0.id == id }
        ranges.removeValue(forKey: id)
        styles.removeValue(forKey: id)
        if selected == id { selected = nil }
    }

    private func loadFrame() {
        let url = session.primary
        let time = media.currentTime
        Task.detached {
            guard let cg = try? await VideoOps.snapshot(url, at: time) else { return }
            let ns = ImageOps.nsImage(cg)
            await MainActor.run { frame = ns }
        }
    }

    private func save() {
        let url = session.primary
        let size = videoSize
        let redactions = rects.map { overlay -> Redaction in
            var r = Redaction(rect: overlay.rect)
            r.style = styles[overlay.id] ?? defaultStyle
            if let range = ranges[overlay.id] { r.start = range.lowerBound; r.end = range.upperBound }
            return r
        }
        let destination = session.outputURL(suffix: "redacted", ext: "mp4")
        session.run(title: "Redacting", detail: "\(url.lastPathComponent)") { progress in
            try await VideoOps.redact(url, redactions: redactions, displaySize: size, to: destination, progress: progress)
            return [destination]
        }
    }
}
