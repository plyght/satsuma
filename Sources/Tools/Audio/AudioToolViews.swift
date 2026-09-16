import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TrimAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var silence: (leading: Double, trailing: Double)?

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Trim", saveEnabled: end > start, onSave: save) {
            VStack(spacing: 10) {
                RangeTrack(duration: media.duration, start: $start, end: $end, playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Range") {
                TimecodeField(title: "Start", seconds: $start, maximum: media.duration)
                TimecodeField(title: "End", seconds: $end, maximum: media.duration)
                HStack {
                    Button("Start at playhead") { start = min(media.currentTime, end - 0.01) }
                    Button("End at playhead") { end = max(media.currentTime, start + 0.01) }
                }
                .controlSize(.small)
                Text("Length: \(TimeFormatter.clock(max(0, end - start)))").font(.callout.monospacedDigit())
            }
            SidebarSection(title: "Silence") {
                Button("Remove silence from beginning and end") {
                    if let silence { start = silence.leading; end = silence.trailing }
                }
                .disabled(silence == nil)
                if let silence {
                    Text("Detected \(TimeFormatter.clock(silence.leading)) leading and \(TimeFormatter.clock(media.duration - silence.trailing)) trailing silence.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Analyzing…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Preview") {
                Button("Play selection") { media.playRange(start, end) }
            }
        }
        .onAppear { media.loadWaveform() }
        .onChange(of: media.duration) { duration in if end == 0 { end = duration } }
        .task { silence = await AudioOps.detectSilence(session.primary) }
    }

    private func save() {
        let url = session.primary, start = start, end = end
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: "trimmed", ext: format.fileExtension)
        session.run(title: "Trimming", detail: "\(url.lastPathComponent)") { progress in
            try await AudioOps.trim(url, start: start, end: end, to: destination, format: format, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct NormalizeAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var target: Double = -16
    @State private var range: Double = 11
    @State private var truePeak: Double = -1.5
    @State private var stats: LoudnessStats?
    @State private var analyzed = false

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Normalize" : "Normalize \(session.files.count) files", onSave: save) {
            VStack(spacing: 14) {
                RangeTrack(duration: media.duration, start: .constant(0), end: .constant(media.duration), playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
                HStack(spacing: 24) {
                    LevelColumn(title: "Input", integrated: stats?.integrated, range: stats?.range, peak: stats?.truePeak, pending: !analyzed)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    LevelColumn(title: "Output", integrated: target, range: range, peak: truePeak, pending: false)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Loudness") {
                LabeledSlider(title: "Target loudness", value: $target, range: -30...(-8)) { String(format: "%.1f LUFS", $0) }
                LabeledSlider(title: "Loudness range", value: $range, range: 1...20) { String(format: "%.0f LU", $0) }
                LabeledSlider(title: "True peak", value: $truePeak, range: -9...0) { String(format: "%.1f dBTP", $0) }
            }
            SidebarSection(title: "Presets") {
                HStack {
                    Button("Podcast") { target = -16; range = 11; truePeak = -1.5 }
                    Button("Music") { target = -14; range = 9; truePeak = -1 }
                    Button("Broadcast") { target = -23; range = 7; truePeak = -2 }
                }
                .controlSize(.small)
            }
            if !FFmpeg.isAvailable {
                SidebarSection(title: "Note") {
                    Text("Without FFmpeg, Satsuma applies peak normalization instead of EBU R128 loudness. Set an FFmpeg path in Settings for full loudness control.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { media.loadWaveform() }
        .task {
            stats = await AudioOps.measureLoudness(session.primary)
            analyzed = true
        }
    }

    private func save() {
        let files = session.files, target = target, range = range, peak = truePeak
        let outputs = files.map { url -> (URL, FileFormat) in
            let format = AudioOps.outputFormat(for: url)
            return (ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url), baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: "normalized", ext: format.fileExtension), format)
        }
        session.run(title: "Normalizing", detail: "\(files.count) file\(files.count == 1 ? "" : "s")") { progress in
            for (index, url) in files.enumerated() {
                let (destination, format) = outputs[index]
                try await AudioOps.normalize(url, targetLUFS: target, range: range, truePeak: peak, to: destination, format: format) { p in
                    progress((Double(index) + p) / Double(files.count))
                }
            }
            return outputs.map(\.0)
        }
    }
}

private struct LevelColumn: View {
    let title: String
    let integrated: Double?
    let range: Double?
    let peak: Double?
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            row("Integrated", integrated, "LUFS")
            row("Range", range, "LU")
            row("True peak", peak, "dBTP")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: Double?, _ unit: String) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            if let value {
                Text(String(format: "%.1f %@", value, unit)).font(.callout.monospacedDigit())
            } else {
                Text(pending ? "…" : "n/a").foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct AudioChannelsToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var mode: AudioOps.ChannelMode = .stereo
    @State private var left: Double = 1
    @State private var right: Double = 1
    @State private var previewChannel: PreviewChannel = .both

    enum PreviewChannel: String, CaseIterable, Identifiable {
        case both, left, right
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save copy", onSave: save) {
            VStack(spacing: 12) {
                RangeTrack(duration: media.duration, start: .constant(0), end: .constant(media.duration), playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
                HStack {
                    Text("Preview").font(.callout)
                    Picker("", selection: $previewChannel) {
                        ForEach(PreviewChannel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    Spacer()
                    Text(media.info.channelCount > 0 ? "\(media.info.channelCount) channel\(media.info.channelCount == 1 ? "" : "s") · \(Int(media.info.sampleRate)) Hz" : "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Channels") {
                Picker("", selection: $mode) {
                    ForEach(AudioOps.ChannelMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            SidebarSection(title: "Volume") {
                LabeledSlider(title: "Left", value: $left, range: 0...2) { String(format: "%.0f%%", $0 * 100) }
                LabeledSlider(title: "Right", value: $right, range: 0...2) { String(format: "%.0f%%", $0 * 100) }
                Button("Reset") { left = 1; right = 1 }.controlSize(.small)
            }
        }
        .onAppear { media.loadWaveform() }
        .onChange(of: previewChannel) { channel in applyPreview(channel) }
        .onChange(of: left) { _ in applyPreview(previewChannel) }
        .onChange(of: right) { _ in applyPreview(previewChannel) }
        .onChange(of: media.loaded) { _ in applyPreview(previewChannel) }
    }

    private func applyPreview(_ channel: PreviewChannel) {
        guard let item = media.player.currentItem, let track = item.asset.tracks(withMediaType: .audio).first else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        let mix = AVMutableAudioMix()
        switch channel {
        case .both: params.setVolume(Float(max(left, right)), at: .zero)
        case .left: params.setVolume(Float(left), at: .zero)
        case .right: params.setVolume(Float(right), at: .zero)
        }
        mix.inputParameters = [params]
        item.audioMix = mix
        media.player.volume = 1
    }

    private func save() {
        let url = session.primary, mode = mode, left = left, right = right
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: mode == .mono ? "mono" : "channels", ext: format.fileExtension)
        session.run(title: "Converting channels", detail: "\(url.lastPathComponent)") { progress in
            try await AudioOps.convertChannels(url, mode: mode, leftGain: left, rightGain: right, to: destination, format: format, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct RedactAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var ranges: [AudioOps.BleepRange] = []
    @State private var selected: UUID?
    @State private var frequency: Double = 1000

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var selectedIndex: Int? { ranges.firstIndex { $0.id == selected } }

    var body: some View {
        ToolShell(session: session, saveTitle: "Bleep", saveEnabled: !ranges.isEmpty, onSave: save) {
            VStack(spacing: 10) {
                RangeTrack(
                    duration: media.duration,
                    start: Binding(get: { selectedIndex.map { ranges[$0].start } ?? 0 }, set: { new in if let i = selectedIndex { ranges[i].start = min(new, ranges[i].end - 0.01) } }),
                    end: Binding(get: { selectedIndex.map { ranges[$0].end } ?? 0 }, set: { new in if let i = selectedIndex { ranges[i].end = max(new, ranges[i].start + 0.01) } }),
                    playhead: media.currentTime,
                    waveform: media.waveform,
                    markers: ranges.flatMap { [$0.start, $0.end] },
                    onScrub: { media.seek($0) }
                )
                .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Bleeps (\(ranges.count))") {
                Button("Add bleep at playhead") {
                    let start = media.currentTime
                    let range = AudioOps.BleepRange(start: start, end: min(media.duration, start + 1))
                    ranges.append(range)
                    selected = range.id
                }
                ForEach(ranges) { range in
                    HStack {
                        Circle().fill(range.id == selected ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        Text("\(TimeFormatter.clock(range.start)) – \(TimeFormatter.clock(range.end))").font(.callout.monospacedDigit())
                        Spacer()
                        Button { media.playRange(range.start, range.end) } label: { Image(systemName: "play.fill") }
                        Button { ranges.removeAll { $0.id == range.id }; if selected == range.id { selected = nil } } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = range.id }
                }
            }
            if let i = selectedIndex {
                SidebarSection(title: "Selected bleep") {
                    TimecodeField(title: "Start", seconds: Binding(get: { ranges[i].start }, set: { ranges[i].start = min($0, ranges[i].end - 0.01) }), maximum: media.duration)
                    TimecodeField(title: "End", seconds: Binding(get: { ranges[i].end }, set: { ranges[i].end = max($0, ranges[i].start + 0.01) }), maximum: media.duration)
                    HStack {
                        Button("Nudge −0.1 s") { shift(i, -0.1) }
                        Button("Nudge +0.1 s") { shift(i, 0.1) }
                    }
                    .controlSize(.small)
                }
            }
            SidebarSection(title: "Tone") {
                LabeledSlider(title: "Frequency", value: $frequency, range: 300...2000) { String(format: "%.0f Hz", $0) }
            }
            SidebarSection(title: "Compare") {
                Text("Play a bleep row to hear the original section. The saved copy replaces those sections with the tone.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { media.loadWaveform() }
    }

    private func shift(_ index: Int, _ delta: Double) {
        let length = ranges[index].end - ranges[index].start
        let start = max(0, min(media.duration - length, ranges[index].start + delta))
        ranges[index].start = start
        ranges[index].end = start + length
    }

    private func save() {
        let url = session.primary, ranges = ranges, frequency = frequency
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: "bleeped", ext: format.fileExtension)
        session.run(title: "Bleeping", detail: "\(url.lastPathComponent)") { progress in
            try await AudioOps.bleep(url, ranges: ranges, frequency: frequency, to: destination, format: format, progress: progress)
            return [destination]
        }
    }
}

@MainActor
struct AudioToVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var style: AudioOps.VisualizerStyle = .waveform
    @State private var orientation: AudioOps.VisualizerOrientation = .landscape
    @State private var accent = Color.orange
    @State private var background = Color.black
    @State private var imageURL: URL?
    @State private var image: NSImage?

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Create MP4", saveEnabled: FFmpeg.isAvailable && (style != .stillImage || imageURL != nil), onSave: save) {
            VStack(spacing: 12) {
                ZStack {
                    background
                    if style == .stillImage {
                        if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Text("Choose an image").foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        WaveformShape(samples: media.waveform.isEmpty ? Array(repeating: 0.3, count: 120) : media.waveform)
                            .fill(accent)
                            .padding(.horizontal, 24)
                            .frame(maxHeight: style == .bars ? .infinity : nil)
                            .opacity(0.95)
                    }
                }
                .aspectRatio(orientation.size.width / orientation.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: "Style") {
                Picker("", selection: $style) {
                    ForEach(AudioOps.VisualizerStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if style == .stillImage {
                    HStack {
                        Text(imageURL?.lastPathComponent ?? "No image").font(.callout).lineLimit(1)
                        Spacer()
                        Button("Choose…") { chooseImage() }
                    }
                }
            }
            SidebarSection(title: "Video") {
                Picker("", selection: $orientation) {
                    ForEach(AudioOps.VisualizerOrientation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("\(Int(orientation.size.width)) × \(Int(orientation.size.height)) · 30 fps · H.264 + AAC").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Colors") {
                if style != .stillImage { ColorSwatchPicker(title: "Accent", color: $accent) }
                ColorSwatchPicker(title: "Background", color: $background)
            }
            if !FFmpeg.isAvailable {
                SidebarSection(title: "Requires FFmpeg") {
                    Text("Rendering a visualizer needs FFmpeg. Set its path in Settings.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { media.loadWaveform(buckets: 240) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imageURL = url
        image = (try? ImageIOBridge.load(url, maxPixelSize: 1200)).map(ImageOps.nsImage)
    }

    private func save() {
        let url = session.primary, style = style, orientation = orientation, imageURL = imageURL
        let accentHex = accent.nsColor.ffmpegHex, backgroundHex = background.nsColor.ffmpegHex
        let destination = session.outputURL(suffix: "visualizer", ext: "mp4")
        session.run(title: "Creating visualizer", detail: "\(url.lastPathComponent)") { progress in
            try await AudioOps.visualize(url, style: style, orientation: orientation, accent: accentHex, background: backgroundHex, image: imageURL, to: destination, progress: progress)
            return [destination]
        }
    }
}

extension NSColor {
    var ffmpegHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "0x%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
