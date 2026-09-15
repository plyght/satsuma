import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var ffmpegStatus = FFmpeg.path

    var body: some View {
        Form {
            Section("Output") {
                Picker("Save converted files", selection: $settings.outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
                Toggle("Show a notification when done", isOn: $settings.showNotifications)
                Toggle("Launch Satsuma at login", isOn: $settings.launchAtLogin)
            }
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Images") {
                HStack {
                    Text("JPEG / HEIC / WebP quality")
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                    Text("\(Int(settings.jpegQuality * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section("Compression") {
                Picker("Preset", selection: $settings.compressionPreset) {
                    ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.compressionPreset == .balanced
                     ? "Balanced keeps detail while trimming size noticeably."
                     : "Strong prioritizes the smallest file, with visible quality loss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Resize long edge to")
                    TextField("Off", value: $settings.compressionResizeLongEdge, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("px (0 = keep size)").foregroundStyle(.secondary)
                }
            }
            Section("FFmpeg (optional)") {
                Text("Satsuma uses Apple frameworks for most work. FFmpeg fills the gaps: MP3, FLAC, OGG, Opus, WMA, MKV, WebM, AVI, WMV, GIF and AVIF/WebP encoding on older systems.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Auto-detect (Homebrew, MacPorts, /usr/local/bin)", text: $settings.ffmpegPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFFmpeg() }
                }
                HStack(spacing: 6) {
                    Image(systemName: ffmpegStatus == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(ffmpegStatus == nil ? .orange : .green)
                    Text(ffmpegStatus.map { "Using \($0)" } ?? "FFmpeg not found. Install with `brew install ffmpeg` or pick the binary.")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            Section("Satsuma") {
                Text("Hold ⇧ Shift while dragging files to convert. Add ⌥ Option for advanced tools. Everything runs on this Mac; nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(ConversionMatrix.totalConversions) conversion options · \(ToolID.total) tools")
                    .font(.caption.monospacedDigit())
            }
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .frame(width: 480)
        .onChange(of: settings.ffmpegPath) { _ in ffmpegStatus = FFmpeg.path }
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.ffmpegPath = url.path
        }
    }
}
