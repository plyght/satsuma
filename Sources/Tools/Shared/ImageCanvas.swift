import AppKit
import SwiftUI

struct FitGeometry {
    let container: CGSize
    let image: CGSize

    var scale: CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return min(container.width / image.width, container.height / image.height, 1000)
    }

    var displayRect: CGRect {
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        let rect = displayRect
        return CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
    }

    func toImage(_ rect: CGRect) -> CGRect {
        let origin = toImage(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width / scale, height: rect.height / scale)
    }

    func toDisplay(_ rect: CGRect) -> CGRect {
        let display = displayRect
        return CGRect(x: display.minX + rect.minX * scale, y: display.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    func clampToImage(_ rect: CGRect) -> CGRect {
        let bounds = CGRect(origin: .zero, size: image)
        var result = rect.standardized.intersection(bounds)
        if result.isNull { result = .zero }
        return result
    }
}

struct RectangleOverlay: Identifiable {
    let id: UUID
    var rect: CGRect
    var color: Color
    var label: String
}

struct RectangleEditorCanvas: View {
    let image: NSImage
    let imageSize: CGSize
    @Binding var rectangles: [RectangleOverlay]
    @Binding var selected: UUID?
    var allowMultiple = true
    var aspect: CGFloat? = nil
    var minimumSize: CGFloat = 8

    @State private var dragStart: CGPoint?
    @State private var dragMode: DragMode = .none
    @State private var originalRect: CGRect = .zero

    private enum DragMode {
        case none
        case create(UUID)
        case move(UUID)
        case resize(UUID, corner: Int)
    }

    var body: some View {
        GeometryReader { proxy in
            let fit = FitGeometry(container: proxy.size, image: imageSize)
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.displayRect.width, height: fit.displayRect.height)
                    .offset(x: fit.displayRect.minX, y: fit.displayRect.minY)
                ForEach(rectangles) { overlay in
                    let display = fit.toDisplay(overlay.rect)
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(overlay.color.opacity(overlay.id == selected ? 0.35 : 0.22))
                        Rectangle()
                            .strokeBorder(overlay.color, lineWidth: overlay.id == selected ? 2 : 1)
                        if !overlay.label.isEmpty {
                            Text(overlay.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(overlay.color, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                                .offset(x: 2, y: 2)
                        }
                        if overlay.id == selected {
                            ForEach(0..<4, id: \.self) { corner in
                                Circle()
                                    .fill(Color.white)
                                    .overlay(Circle().stroke(overlay.color, lineWidth: 1.5))
                                    .frame(width: 10, height: 10)
                                    .position(cornerPoint(corner, in: CGRect(origin: .zero, size: display.size)))
                            }
                        }
                    }
                    .frame(width: max(display.width, 1), height: max(display.height, 1))
                    .offset(x: display.minX, y: display.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in handleChanged(value, fit: fit) }
                    .onEnded { value in handleEnded(value, fit: fit) }
            )
        }
    }

    private func cornerPoint(_ corner: Int, in rect: CGRect) -> CGPoint {
        switch corner {
        case 0: return CGPoint(x: rect.minX, y: rect.minY)
        case 1: return CGPoint(x: rect.maxX, y: rect.minY)
        case 2: return CGPoint(x: rect.maxX, y: rect.maxY)
        default: return CGPoint(x: rect.minX, y: rect.maxY)
        }
    }

    private func handleChanged(_ value: DragGesture.Value, fit: FitGeometry) {
        let current = fit.toImage(value.location)
        if dragStart == nil {
            let start = fit.toImage(value.startLocation)
            dragStart = start
            if let selectedID = selected, let overlay = rectangles.first(where: { $0.id == selectedID }) {
                let handle = 12 / fit.scale
                for corner in 0..<4 {
                    let point = cornerPoint(corner, in: overlay.rect)
                    if abs(point.x - start.x) < handle, abs(point.y - start.y) < handle {
                        dragMode = .resize(selectedID, corner: corner)
                        originalRect = overlay.rect
                        return
                    }
                }
            }
            if let hit = rectangles.last(where: { $0.rect.insetBy(dx: -4 / fit.scale, dy: -4 / fit.scale).contains(start) }) {
                selected = hit.id
                dragMode = .move(hit.id)
                originalRect = hit.rect
                return
            }
            let id = UUID()
            if !allowMultiple { rectangles.removeAll() }
            rectangles.append(RectangleOverlay(id: id, rect: CGRect(origin: start, size: .zero), color: .orange, label: allowMultiple ? "\(rectangles.count + 1)" : ""))
            selected = id
            dragMode = .create(id)
            return
        }
        guard let start = dragStart else { return }
        switch dragMode {
        case .create(let id):
            var rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            if let aspect, aspect > 0 {
                let width = rect.width
                let height = width / aspect
                rect = CGRect(x: rect.minX, y: current.y < start.y ? start.y - height : start.y, width: width, height: height)
            }
            update(id, fit.clampToImage(rect))
        case .move(let id):
            var rect = originalRect.offsetBy(dx: current.x - start.x, dy: current.y - start.y)
            rect.origin.x = min(max(0, rect.minX), imageSize.width - rect.width)
            rect.origin.y = min(max(0, rect.minY), imageSize.height - rect.height)
            update(id, rect)
        case .resize(let id, let corner):
            var rect = originalRect
            switch corner {
            case 0: rect = CGRect(x: current.x, y: current.y, width: rect.maxX - current.x, height: rect.maxY - current.y)
            case 1: rect = CGRect(x: rect.minX, y: current.y, width: current.x - rect.minX, height: rect.maxY - current.y)
            case 2: rect = CGRect(x: rect.minX, y: rect.minY, width: current.x - rect.minX, height: current.y - rect.minY)
            default: rect = CGRect(x: current.x, y: rect.minY, width: rect.maxX - current.x, height: current.y - rect.minY)
            }
            rect = rect.standardized
            if let aspect, aspect > 0 {
                let height = rect.width / aspect
                rect = CGRect(x: rect.minX, y: corner < 2 ? rect.maxY - height : rect.minY, width: rect.width, height: height)
            }
            update(id, fit.clampToImage(rect))
        case .none:
            break
        }
    }

    private func update(_ id: UUID, _ rect: CGRect) {
        guard let index = rectangles.firstIndex(where: { $0.id == id }) else { return }
        rectangles[index].rect = rect
    }

    private func handleEnded(_ value: DragGesture.Value, fit: FitGeometry) {
        if case .create(let id) = dragMode, let index = rectangles.firstIndex(where: { $0.id == id }) {
            let rect = rectangles[index].rect
            if rect.width < minimumSize || rect.height < minimumSize {
                rectangles.remove(at: index)
                let point = fit.toImage(value.startLocation)
                selected = rectangles.last(where: { $0.rect.contains(point) })?.id
            }
        }
        dragStart = nil
        dragMode = .none
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    let dark = (row + col) % 2 == 0
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(dark ? Color(white: 0.22) : Color(white: 0.26)))
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
        }
    }
}

@MainActor
final class ImageDocument: ObservableObject {
    @Published var original: CGImage?
    @Published var preview: NSImage?
    @Published var error: String?
    let url: URL

    var size: CGSize {
        guard let original else { return .zero }
        return CGSize(width: original.width, height: original.height)
    }

    init(url: URL, previewMaxPixels: Int? = 2400) {
        self.url = url
        Task.detached { [url] in
            do {
                let full = try ImageIOBridge.load(url)
                let previewImage = previewMaxPixels.map { ImageIOBridge.resized(full, longEdge: $0) } ?? full
                await MainActor.run {
                    self.original = full
                    self.preview = ImageOps.nsImage(previewImage)
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

struct LoadingOrError: View {
    let error: String?

    var body: some View {
        VStack(spacing: 10) {
            if let error {
                Icon(.alertTriangle, size: 40).font(.largeTitle).foregroundStyle(.orange)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension NSColor {
    var swiftUIColor: Color { Color(nsColor: self) }
}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}
