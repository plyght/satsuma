import SwiftUI

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

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Compress" : "Compress \(session.files.count) files", onSave: run) {
            List(session.files, id: \.self) { url in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent).lineLimit(1)
                        Text("\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) → \(Compressor.outputFormat(for: url).displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        } sidebar: {
            SidebarSection(title: "Preset") {
                Picker("", selection: $settings.compressionPreset) {
                    ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.compressionPreset == .balanced ? "Noticeably smaller with little visible change." : "Smallest output; quality loss is visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Target size") {
                Toggle("Aim for an exact file size", isOn: $useTarget)
                HStack {
                    TextField("Size", value: $targetValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Picker("", selection: $targetUnit) {
                        ForEach(SizeUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    Text("per file").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!useTarget)
                Text("Images use a quality search and downscale if needed. Videos and audio pick a bitrate from the duration (FFmpeg required).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Resize images") {
                NumberField(title: "Long edge", value: $resize, suffix: "px")
                Text("0 keeps the original dimensions.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Summary") {
                Text("\(session.files.count) file\(session.files.count == 1 ? "" : "s"), \(FileSizeFormatter.string(totalSize)) total")
                    .font(.callout)
                Text("Originals are never modified; compressed copies are saved to \(settings.outputLocation.title.lowercased()).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
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
