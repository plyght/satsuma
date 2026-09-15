import AVFoundation
import AppKit
import CoreGraphics
import CoreText

@MainActor
enum ScreenshotDriver {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["SATSUMA_SCREENSHOTS"] != nil }

    static func run(radial: RadialController) {
        guard let directory = ProcessInfo.processInfo.environment["SATSUMA_SCREENSHOTS"].map({ URL(fileURLWithPath: $0) }) else { return }
        Task {
            do {
                try await capture(into: directory, radial: radial)
                print("screenshots written to \(directory.path)")
                exit(0)
            } catch {
                fputs("screenshot run failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private static func capture(into directory: URL, radial: RadialController) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = directory.appendingPathComponent("samples")
        try fm.createDirectory(at: samples, withIntermediateDirectories: true)

        let photo = samples.appendingPathComponent("photo.png")
        let photo2 = samples.appendingPathComponent("photo 2.jpg")
        let pdf = samples.appendingPathComponent("report.pdf")
        let pdf2 = samples.appendingPathComponent("appendix.pdf")
        let audio = samples.appendingPathComponent("voice.wav")
        let video = samples.appendingPathComponent("clip.mp4")
        let video2 = samples.appendingPathComponent("clip 2.mp4")

        try ImageIOBridge.write(SampleMedia.image(width: 1600, height: 1000, hue: 0.08), to: photo, format: .png)
        try ImageIOBridge.write(SampleMedia.image(width: 1200, height: 1200, hue: 0.55), to: photo2, format: .jpg)
        try PDFRenderer.writeImagesPDF([photo, photo2, photo], pageSize: CGSize(width: 612, height: 792), to: pdf) { _ in }
        try PDFRenderer.writeImagesPDF([photo2, photo], pageSize: CGSize(width: 612, height: 792), to: pdf2) { _ in }
        try SampleMedia.writeTone(to: audio, seconds: 6)
        try await SampleMedia.writeVideo(to: video, seconds: 4, hue: 0.08)
        try await SampleMedia.writeVideo(to: video2, seconds: 3, hue: 0.6)

        let inputs: [ToolID: [URL]] = [
            .compress: [photo, pdf, video],
            .editMetadata: [photo],
            .editImage: [photo],
            .frameImage: [photo],
            .cropImage: [photo],
            .redactImage: [photo],
            .resizeImage: [photo, photo2],
            .rotateImage: [photo],
            .createPDF: [photo, photo2],
            .createCollage: [photo, photo2, photo],
            .trimVideo: [video],
            .cropVideo: [video],
            .changeVideoSpeed: [video],
            .joinVideos: [video, video2],
            .videoSnapshots: [video],
            .splitVideo: [video],
            .redactVideo: [video],
            .normalizeAudio: [audio],
            .audioToVideo: [audio],
            .trimAudio: [audio],
            .audioChannels: [audio],
            .redactAudio: [audio],
            .mergePDF: [pdf, pdf2],
            .organizePDF: [pdf],
            .splitPDF: [pdf],
        ]

        radial.presentPicker(for: [photo], advanced: false)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await screencapture(["-x", directory.appendingPathComponent("radial-convert.png").path])
        radial.hide()
        radial.presentPicker(for: [photo], advanced: true)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await screencapture(["-x", directory.appendingPathComponent("radial-tools.png").path])
        radial.hide()

        for tool in ToolID.allCases {
            guard let files = inputs[tool] else { continue }
            print("opening \(tool.rawValue)")
            fflush(stdout)
            ToolWindowManager.shared.open(tool, files: files)
            try await Task.sleep(nanoseconds: 2_500_000_000)
            for window in ToolWindowManager.shared.openWindows {
                try await screencapture(["-x", "-o", "-l", "\(window.windowNumber)", directory.appendingPathComponent("tool-\(tool.rawValue).png").path])
            }
            ToolWindowManager.shared.closeAll()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try? fm.removeItem(at: samples)
    }

    private static func screencapture(_ arguments: [String]) async throws {
        let result = try await Shell.run("/usr/sbin/screencapture", arguments)
        guard result.succeeded else { throw SatsumaError.toolFailed("screencapture", result.stderr) }
    }
}

enum SampleMedia {
    static func image(width: Int, height: Int, hue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [NSColor(hue: hue, saturation: 0.75, brightness: 0.95, alpha: 1).cgColor, NSColor(hue: hue + 0.12, saturation: 0.6, brightness: 0.4, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for i in 0..<12 {
            let r = CGFloat(40 + i * 23)
            context.setFillColor(NSColor.white.withAlphaComponent(0.08 + CGFloat(i % 3) * 0.06).cgColor)
            context.fillEllipse(in: CGRect(x: CGFloat(width) * CGFloat((i * 7) % 10) / 10, y: CGFloat(height) * CGFloat((i * 3) % 10) / 10, width: r, height: r))
        }
        let text = NSAttributedString(string: "Satsuma", attributes: [.font: NSFont.systemFont(ofSize: CGFloat(width) / 8, weight: .bold), .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: (CGFloat(height) - bounds.height) / 2)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    static func writeTone(to url: URL, seconds: Double) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let envelope = Float(0.2 + 0.6 * abs(sin(t * 1.3)))
            left[i] = envelope * Float(sin(2 * .pi * 220 * t)) * 0.5
            right[i] = envelope * Float(sin(2 * .pi * 330 * t)) * 0.4
        }
        try file.write(from: buffer)
    }

    static func writeVideo(to url: URL, seconds: Double, hue: CGFloat) async throws {
        let width = 1280, height = 720, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SatsumaError.encodeFailed(url.lastPathComponent) }
        writer.startSession(atSourceTime: .zero)
        let total = Int(seconds * Double(fps))
        for frame in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw SatsumaError.encodeFailed(url.lastPathComponent) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixelBuffer = buffer else { throw SatsumaError.encodeFailed(url.lastPathComponent) }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let progress = CGFloat(frame) / CGFloat(max(1, total - 1))
            context.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: 0.35 + 0.3 * progress, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: CGRect(x: 100 + progress * CGFloat(width - 400), y: CGFloat(height) / 2 - 100, width: 200, height: 200))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
