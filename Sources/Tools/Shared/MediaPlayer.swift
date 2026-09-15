import AVFoundation
import AVKit
import Combine
import SwiftUI

@MainActor
final class MediaController: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var info = MediaInfo()
    @Published var loaded = false
    @Published var waveform: [Float] = []
    private var observer: Any?
    private var endObserver: Any?
    private var boundaryObserver: Any?

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = CMTimeGetSeconds(time)
            self.isPlaying = self.player.rate != 0
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            self?.isPlaying = false
        }
        Task {
            let info = await MediaInfo.load(url)
            self.info = info
            self.duration = info.duration
            self.loaded = true
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func loadWaveform(buckets: Int = 600) {
        Task.detached { [url] in
            let samples = await AudioOps.waveform(url, buckets: buckets)
            await MainActor.run { self.waveform = samples }
        }
    }

    func seek(_ seconds: Double, exact: Bool = true) {
        let time = CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600)
        if exact {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: time)
        }
        currentTime = CMTimeGetSeconds(time)
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.01 { seek(0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func pause() { player.pause(); isPlaying = false }

    func stepFrame(_ delta: Int) {
        pause()
        if let item = player.currentItem, (delta > 0 ? item.canStepForward : item.canStepBackward) {
            item.step(byCount: delta)
            currentTime = CMTimeGetSeconds(item.currentTime())
        } else {
            let frame = info.frameRate > 0 ? 1 / info.frameRate : 1 / 30
            seek(currentTime + Double(delta) * frame)
        }
    }

    func playRange(_ start: Double, _ end: Double) {
        seek(start)
        player.play()
        isPlaying = true
        let boundary = CMTime(seconds: end, preferredTimescale: 600)
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: boundary)], queue: .main) { [weak self] in
            guard let self else { return }
            self.pause()
            if let token = self.boundaryObserver {
                self.player.removeTimeObserver(token)
                self.boundaryObserver = nil
            }
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var showsControls = false

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = showsControls ? .inline : .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

struct TransportBar: View {
    @ObservedObject var controller: MediaController
    var showFrameSteps = true

    var body: some View {
        HStack(spacing: 10) {
            if showFrameSteps {
                Button { controller.stepFrame(-1) } label: { Image(systemName: "backward.frame") }
                    .help("Previous frame")
            }
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            if showFrameSteps {
                Button { controller.stepFrame(1) } label: { Image(systemName: "forward.frame") }
                    .help("Next frame")
            }
            Text(TimeFormatter.clock(controller.currentTime))
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Slider(value: Binding(get: { controller.currentTime }, set: { controller.seek($0, exact: false) }), in: 0...max(controller.duration, 0.01))
            Text(TimeFormatter.clock(controller.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }
}

struct RangeTrack: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var playhead: Double = 0
    var waveform: [Float] = []
    var markers: [Double] = []
    var onScrub: ((Double) -> Void)? = nil

    @State private var dragging: Handle?
    private enum Handle { case start, end, playhead }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                if !waveform.isEmpty {
                    WaveformShape(samples: waveform).fill(Color.secondary.opacity(0.45))
                }
                Rectangle()
                    .fill(Color.orange.opacity(0.18))
                    .frame(width: max(0, x(end, width) - x(start, width)))
                    .offset(x: x(start, width))
                ForEach(markers.indices, id: \.self) { index in
                    Rectangle().fill(Color.blue).frame(width: 2).offset(x: x(markers[index], width) - 1)
                }
                handle(x: x(start, width), height: height, color: .orange)
                handle(x: x(end, width), height: height, color: .orange)
                Rectangle().fill(Color.white).frame(width: 2).offset(x: x(playhead, width) - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = t(value.location.x, width)
                        if dragging == nil {
                            let sx = x(start, width), ex = x(end, width)
                            if abs(value.startLocation.x - sx) < 10 { dragging = .start }
                            else if abs(value.startLocation.x - ex) < 10 { dragging = .end }
                            else { dragging = .playhead }
                        }
                        switch dragging {
                        case .start: start = min(time, end - 0.05)
                        case .end: end = max(time, start + 0.05)
                        case .playhead: onScrub?(time)
                        case nil: break
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .frame(height: 56)
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func t(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width) * duration), duration)
    }

    private func handle(x: CGFloat, height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: 8, height: height)
            .offset(x: x - 4)
    }
}

struct WaveformShape: Shape {
    let samples: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        let step = rect.width / CGFloat(samples.count)
        let mid = rect.midY
        for (index, sample) in samples.enumerated() {
            let h = max(1, CGFloat(sample) * rect.height * 0.95)
            path.addRect(CGRect(x: rect.minX + CGFloat(index) * step, y: mid - h / 2, width: max(1, step - 1), height: h))
        }
        return path
    }
}
