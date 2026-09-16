import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case conversion
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .conversion: return "Conversion"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .conversion: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var tab: SettingsTab = .general
    @State private var ffmpegStatus = FFmpeg.path

    static let width: CGFloat = 520
    static let height: CGFloat = 560
    static let barHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab)
                .frame(height: Self.barHeight)
            Form {
                switch tab {
                case .general: general
                case .appearance: appearance
                case .conversion: conversion
                case .about: about
                }
            }
            .formStyle(.grouped)
            .id(tab)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.18), value: tab)
        .frame(width: Self.width, height: Self.height)
        .tint(Theme.accent)
        .onChange(of: settings.ffmpegPath) { ffmpegStatus = FFmpeg.path }
    }

    @ViewBuilder private var general: some View {
        Section("Output") {
            Picker("Save converted files", selection: $settings.outputLocation) {
                ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
        }
        Section("General") {
            Toggle("Launch Satsuma at login", isOn: $settings.launchAtLogin)
        }
        Section {
            LabeledContent("Conversion wheel") {
                Label("Shift", systemImage: "shift").labelStyle(.titleAndIcon)
            }
            LabeledContent("Tools wheel") {
                Label("Option + Shift", systemImage: "option").labelStyle(.titleAndIcon)
            }
        } header: {
            Text("Drag Modifiers")
        } footer: {
            Text("Hold the modifier while dragging files in Finder.")
        }
    }

    @ViewBuilder private var appearance: some View {
        Section("Theme") {
            Picker("Theme", selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section {
            Picker("Progress", selection: $settings.progressStyle) {
                ForEach(ProgressStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Progress")
        } footer: {
            Text(settings.progressStyle == .card
                 ? "A floating card in the top right corner with the file name and percentage."
                 : "A tiny progress bar in a pill below the notch.")
        }
    }

    @ViewBuilder private var conversion: some View {
        Section("Images") {
            HStack {
                Text("JPEG / HEIC / WebP quality")
                Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                Text("\(Int(settings.jpegQuality * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
        Section {
            Picker("Preset", selection: $settings.compressionPreset) {
                ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Resize long edge to")
                TextField("Off", value: $settings.compressionResizeLongEdge, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("px (0 = keep size)").foregroundStyle(.secondary)
            }
        } header: {
            Text("Compression")
        } footer: {
            Text(settings.compressionPreset == .balanced
                 ? "Balanced keeps detail while trimming size noticeably."
                 : "Strong prioritizes the smallest file, with visible quality loss.")
        }
        Section {
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
        } header: {
            Text("FFmpeg (optional)")
        } footer: {
            Text("Satsuma uses Apple frameworks for most work. FFmpeg fills the gaps: MP3, FLAC, OGG, Opus, WMA, MKV, WebM, AVI, WMV, GIF and AVIF/WebP encoding on older systems.")
        }
    }

    @ViewBuilder private var about: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Satsuma").font(.title2.weight(.semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        Section {
            LabeledContent("Conversions", value: "\(ConversionMatrix.totalConversions)")
            LabeledContent("Tools", value: "\(ToolID.total)")
        } footer: {
            Text("Hold Shift while dragging files to convert. Add Option for advanced tools. Everything runs on this Mac; nothing is uploaded.")
        }
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

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 78)
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            selection = tab
                        } label: {
                            Label(tab.title, systemImage: tab.symbol)
                                .labelStyle(.titleOnly)
                                .font(.system(size: 13, weight: selection == tab ? .semibold : .regular))
                                .foregroundStyle(selection == tab ? Color.white : Color.primary)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .background {
                            if selection == tab {
                                Color.clear
                                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: Capsule())
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: Capsule())
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: 78)
        }
        .padding(.horizontal, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
    }
}
