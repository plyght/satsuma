import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CropVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var frame: NSImage?
    @State private var rects: [RectangleOverlay] = []
    @State private var selected: UUID?
    @State private var aspect = AspectPreset.all[0]
    @State private var outWidth = 0
    @State private var outHeight = 0
    @State private var keepSize = true

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var cropRect: CGRect? { rects.first?.rect }
    private var videoSize: CGSize { media.info.naturalSize }
    private var aspectRatio: CGFloat? {
        guard let ratio = aspect.ratio else { return nil }
        if ratio < 0, videoSize.height > 0 { return videoSize.width / videoSize.height }
        return ratio
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Crop", saveEnabled: cropRect.map { $0.width > 8 && $0.height > 8 } ?? false, onSave: save) {
            VStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let frame {
                        RectangleEditorCanvas(image: frame, imageSize: videoSize, rectangles: $rects, selected: $selected, allowMultiple: false, aspect: aspectRatio)
                    } else {
                        ProgressView()
                    }
                }
                TransportBar(controller: media)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Aspect ratio") {
                Picker("", selection: $aspect) {
                    ForEach(AspectPreset.all) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            SidebarSection(title: "Crop area") {
                if let rect = cropRect {
                    Text("\(Int(rect.width)) × \(Int(rect.height)) at \(Int(rect.minX)), \(Int(rect.minY))").font(.callout.monospacedDigit())
                }
                Text("Video: \(Int(videoSize.width)) × \(Int(videoSize.height))").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Output dimensions") {
                Toggle("Same as crop area", isOn: $keepSize)
                NumberField(title: "Width", value: $outWidth, suffix: "px").disabled(keepSize)
                NumberField(title: "Height", value: $outHeight, suffix: "px").disabled(keepSize)
                Text("Audio is kept as is. Output is MP4 (H.264).").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.currentTime) { _ in loadFrame() }
        .onChange(of: media.loaded) { loaded in
            guard loaded else { return }
            loadFrame()
            let inset = CGRect(origin: .zero, size: videoSize).insetBy(dx: videoSize.width * 0.1, dy: videoSize.height * 0.1)
            let id = UUID()
            rects = [RectangleOverlay(id: id, rect: inset.integral, color: .orange, label: "")]
            selected = id
        }
        .onChange(of: rects) { new in
            if keepSize, let rect = new.first?.rect { outWidth = Int(rect.width); outHeight = Int(rect.height) }
        }
        .onChange(of: aspect) { _ in
            guard let ratio = aspectRatio, let rect = cropRect else { return }
            var new = rect
            new.size.height = rect.width / ratio
            if new.maxY > videoSize.height { new.size.height = videoSize.height - rect.minY; new.size.width = new.height * ratio }
            rects = [RectangleOverlay(id: rects[0].id, rect: new.integral, color: .orange, label: "")]
        }
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
        guard let rect = cropRect else { return }
        let url = session.primary
        let even = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: (rect.width / 2).rounded(.down) * 2, height: (rect.height / 2).rounded(.down) * 2)
        let output: CGSize? = keepSize ? nil : CGSize(width: (CGFloat(outWidth) / 2).rounded(.down) * 2, height: (CGFloat(outHeight) / 2).rounded(.down) * 2)
        let destination = session.outputURL(suffix: "cropped", ext: "mp4")
        session.run(title: "Crop \(url.lastPathComponent)") { progress in
            try await VideoOps.crop(url, rect: even, outputSize: output, to: destination, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct VideoSpeedToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var factor: Double = 2
    @State private var preservePitch = true

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save copy", onSave: save) {
            VStack(spacing: 10) {
                PlayerSurface(player: media.player).background(Color.black)
                TransportBar(controller: media)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Speed") {
                LabeledSlider(title: "Factor", value: $factor, range: 0.1...8) { String(format: "%.2f×", $0) }
                HStack {
                    ForEach([0.25, 0.5, 1.5, 2, 4], id: \.self) { value in
                        Button(String(format: "%g×", value)) { factor = value }.controlSize(.mini)
                    }
                }
                Text("New length: \(TimeFormatter.clock(media.duration / factor))").font(.callout.monospacedDigit())
            }
            SidebarSection(title: "Audio") {
                Toggle("Preserve pitch", isOn: $preservePitch).disabled(!media.info.hasAudio)
                Text(media.info.hasAudio ? "Pitch is kept natural; disable for a classic tape-speed effect." : "This video has no audio track.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Preview") {
                Button(media.isPlaying ? "Pause" : "Play at \(String(format: "%g", factor))×") {
                    if media.isPlaying { media.pause() } else {
                        media.player.currentItem?.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
                        media.player.rate = Float(factor)
                        media.isPlaying = true
                    }
                }
            }
        }
    }

    private func save() {
        let url = session.primary, factor = factor, pitch = preservePitch
        let destination = session.outputURL(suffix: String(format: "%gx", factor), ext: "mp4")
        session.run(title: "Change speed \(url.lastPathComponent)") { progress in
            try await VideoOps.changeSpeed(url, factor: factor, preservePitch: pitch, to: destination, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct JoinVideosToolView: View {
    let session: ToolSession
    @State private var files: [URL]
    @State private var thumbs: [URL: NSImage] = [:]
    @State private var infos: [URL: MediaInfo] = [:]

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    private var totalDuration: Double { files.reduce(0) { $0 + (infos[$1]?.duration ?? 0) } }

    var body: some View {
        ToolShell(session: session, saveTitle: "Join \(files.count) clips", saveEnabled: files.count >= 2, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs, allowedTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie], addTitle: "Add clips…")
        } sidebar: {
            SidebarSection(title: "Canvas") {
                if let first = files.first, let info = infos[first] {
                    Text("\(Int(info.naturalSize.width)) × \(Int(info.naturalSize.height)) from the first clip").font(.callout)
                }
                Text("Other clips are scaled to fit and letterboxed if their aspect ratio differs. Output is a single MP4.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Summary") {
                Text("\(files.count) clips · \(TimeFormatter.clock(totalDuration))").font(.callout.monospacedDigit())
            }
        }
        .task(id: files) { await loadInfo() }
    }

    private func loadInfo() async {
        for url in files where infos[url] == nil {
            infos[url] = await MediaInfo.load(url)
            if let cg = try? await VideoOps.snapshot(url, at: 0.5) {
                thumbs[url] = ImageOps.nsImage(ImageIOBridge.resized(cg, longEdge: 200))
            }
        }
    }

    private func save() {
        let files = files
        let destination = session.outputURL(suffix: "joined", ext: "mp4")
        session.run(title: "Join \(files.count) videos") { progress in
            try await VideoOps.join(files, to: destination, progress: progress)
            return [destination]
        }
    }
}
