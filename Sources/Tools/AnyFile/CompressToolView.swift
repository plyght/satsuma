import SwiftUI

@MainActor
struct CompressToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var useTarget = false
    @State private var targetValue: Double = 1
    @State private var targetUnit: SizeUnit = .megabytes
    @State private var resize = 0

    enum SizeUnit: String, CaseIterable, Identifiable {
        case kilobytes = "KB"
        case megabytes = "MB"
        var id: String { rawValue }
        var multiplier: Double { self == .kilobytes ? 1_000 : 1_000_000 }
    }

    private var totalSize: Int64 { session.files.reduce(0) { $0 + FileSizeFormatter.size(of: $1) } }
    private var perFileTarget: Int64? {
        guard useTarget else { return nil }
        return Int64(targetValue * targetUnit.multiplier)
    }

    private enum ImageSize: Int, CaseIterable, Identifiable {
        case original = 0
        case large = 2560
        case medium = 1920
        case small = 1280

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .original: return "Original"
            case .large: return "2560 px"
            case .medium: return "1920 px"
            case .small: return "1280 px"
            }
        }
    }

    private var imageSize: Binding<ImageSize> {
        Binding(
            get: { ImageSize(rawValue: resize) ?? .original },
            set: { resize = $0.rawValue }
        )
    }

    private var hasImages: Bool { session.files.contains { FileFormat.detect($0)?.category == .image } }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? "Compress" : "Compress \(session.files.count) files", onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · saves as \(Compressor.outputFormat(for: url).displayName)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            FormRow(title: "Compression") {
                SegmentedPicker(selection: $settings.compressionPreset, options: CompressionPreset.allCases.map { ($0, $0.title) })
            }
            FormHint(settings.compressionPreset == .balanced ? "Noticeably smaller with little visible change." : "Smallest output; quality loss is visible.")

            if hasImages {
                FormRow(title: "Image size") {
                    SegmentedPicker(selection: imageSize, options: ImageSize.allCases.map { ($0, $0.title) })
                }
                FormHint("Longest edge of each image. Smaller images are never upscaled.")
            }

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $useTarget.animation(.easeInOut(duration: 0.18))) {
                    Text("Target file size")
                }
                .toggleStyle(.switch)

                if useTarget {
                    HStack(spacing: 10) {
                        TextField("Size", value: $targetValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                        SegmentedPicker(selection: $targetUnit, options: SizeUnit.allCases.map { ($0, $0.rawValue) })
                        Text("per file")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    FormHint("Images use a quality search and downscale if needed. Videos and audio pick a bitrate from the duration (FFmpeg required).")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Text("\(session.files.count) file\(session.files.count == 1 ? "" : "s"), \(FileSizeFormatter.string(totalSize)) total. Originals stay untouched; compressed copies are saved to \(settings.outputLocation.title.lowercased()).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { resize = settings.compressionResizeLongEdge }
    }

    private func run() {
        let preset = settings.compressionPreset
        let target = perFileTarget
        let resize = resize
        for url in session.files {
            let format = Compressor.outputFormat(for: url)
            let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
            let destination = ConversionMatrix.uniqueURL(directory: settings.outputLocation.directory(for: url), baseName: base, suffix: "compressed", ext: format.fileExtension)
            JobRunner.shared.run(title: "Compress \(url.lastPathComponent)") { progress in
                try await Compressor.compress(url, preset: preset, resizeLongEdge: resize, targetBytes: target, to: destination, progress: progress)
                return [destination]
            }
        }
        ToolWindowManager.shared.close(session)
    }
}
