import AppKit

enum RadialAction: Hashable {
    case convert(FileFormat)
    case tool(ToolID)
}

struct RadialItem: Identifiable, Hashable {
    let action: RadialAction
    let label: String
    let detail: String
    let icon: Reicon?

    var id: RadialAction { action }

    init(format: FileFormat) {
        action = .convert(format)
        label = format.displayName
        detail = "Convert to \(format.displayName)"
        icon = nil
    }

    init(tool: ToolID) {
        action = .tool(tool)
        label = tool.radialLabel
        detail = tool.title
        icon = tool.icon
    }
}

final class RadialBackdrop: NSView {
    private let glass: NSView

    override init(frame frameRect: NSRect) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.cornerRadius = frameRect.width / 2
            view.tintColor = NSColor.white.withAlphaComponent(0.35)
            glass = view
        } else {
            glass = RadialBackdrop.material()
        }
        #else
        glass = RadialBackdrop.material()
        #endif
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = frameRect.width / 2
        layer?.masksToBounds = true
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    private static func material() -> NSView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }
}

final class RadialCanvas: NSView {
    weak var owner: RadialView?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        owner?.render()
    }
}

final class RadialView: NSView {
    var items: [RadialItem] = [] { didSet { needsLayout = true; canvas.needsDisplay = true } }
    var emptyMessage = "No conversions available"
    var subtitle = ""
    var center: NSPoint = .zero { didSet { needsLayout = true; canvas.needsDisplay = true } }
    var accent = Theme.accentNS
    var onSelect: ((RadialItem) -> Void)?
    var onCancel: (() -> Void)?
    var interactive = false
    var advancedMode = false { didSet { canvas.needsDisplay = true } }

    private(set) var highlighted: Int? { didSet { if oldValue != highlighted { canvas.needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    private let backdrop: RadialBackdrop
    private let canvas = RadialCanvas(frame: .zero)

    let innerRadius: CGFloat = 58
    let outerRadius: CGFloat = 142
    let discRadius: CGFloat = 156
    private let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private let muted = NSColor(srgbRed: 0.50, green: 0.51, blue: 0.54, alpha: 1)

    override init(frame frameRect: NSRect) {
        backdrop = RadialBackdrop(frame: NSRect(x: 0, y: 0, width: discRadius * 2, height: discRadius * 2))
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        addSubview(backdrop)
        canvas.owner = self
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
    }

    override func layout() {
        super.layout()
        backdrop.frame = NSRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2)
        backdrop.isHidden = items.isEmpty
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func index(at point: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance >= innerRadius, distance <= outerRadius + 24 else { return nil }
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        let slice = 2 * .pi / CGFloat(items.count)
        var relative = CGFloat.pi / 2 + slice / 2 - angle
        while relative < 0 { relative += 2 * .pi }
        while relative >= 2 * .pi { relative -= 2 * .pi }
        return min(items.count - 1, Int(relative / slice))
    }

    private func angles(for index: Int) -> (start: CGFloat, end: CGFloat) {
        let slice = 2 * .pi / CGFloat(items.count)
        let top = CGFloat.pi / 2
        let end = top - slice * CGFloat(index) + slice / 2
        let start = end - slice
        return (start, end)
    }

    func render() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let count = items.count
        if count == 0 {
            drawEmpty()
            return
        }

        drawDisc(context)

        let slice = 2 * CGFloat.pi / CGFloat(count)
        let corner: CGFloat = count > 6 ? 9 : 12
        let gap: CGFloat = 5
        for index in 0..<count {
            let (start, end) = angles(for: index)
            let isHighlighted = highlighted == index
            let path = petal(start: start, end: end, gap: gap, corner: corner)

            context.saveGState()
            if isHighlighted {
                context.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: accent.withAlphaComponent(0.45).cgColor)
                accent.setFill()
                accent.setStroke()
            } else {
                context.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(0.06).cgColor)
                context.setAlpha(Theme.supportsLiquidGlass ? 0.72 : 0.9)
                NSColor.white.setFill()
                NSColor.white.setStroke()
            }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            path.fill()
            path.lineWidth = corner * 2
            path.lineJoinStyle = .round
            path.stroke()
            context.endTransparencyLayer()
            context.restoreGState()

            if !isHighlighted {
                context.saveGState()
                path.addClip()
                let gradient = NSGradient(colors: [NSColor.white.withAlphaComponent(0.9), NSColor.white.withAlphaComponent(0.0)])
                let mid = (start + end) / 2
                let radius = (innerRadius + outerRadius) / 2
                let point = NSPoint(x: center.x + cos(mid) * radius, y: center.y + sin(mid) * radius)
                gradient?.draw(fromCenter: point, radius: 0, toCenter: point, radius: (outerRadius - innerRadius) * 0.55, options: [])
                context.restoreGState()
            }

            drawLabel(items[index], start: start, end: end, highlighted: isHighlighted, count: count, slice: slice)
        }

        let title: String
        if let highlighted, highlighted < items.count {
            title = items[highlighted].label
        } else {
            title = items.count == 1 ? items[0].label : (advancedMode ? "TOOLS" : "CONVERT")
        }
        drawPill(title)

        let caption = (highlighted.flatMap { $0 < items.count ? items[$0].detail : nil }) ?? subtitle
        drawCaption(caption)
    }

    private func petal(start: CGFloat, end: CGFloat, gap: CGFloat, corner: CGFloat) -> NSBezierPath {
        let inner = innerRadius + gap / 2 + corner
        let outer = outerRadius - gap / 2 - corner
        let innerShift = (gap / 2 + corner) / inner
        let outerShift = (gap / 2 + corner) / outer
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer, startAngle: (start + outerShift) * 180 / .pi, endAngle: (end - outerShift) * 180 / .pi)
        path.appendArc(withCenter: center, radius: inner, startAngle: (end - innerShift) * 180 / .pi, endAngle: (start + innerShift) * 180 / .pi, clockwise: true)
        path.close()
        return path
    }

    private func drawDisc(_ context: CGContext) {
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2))
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 34, color: NSColor.black.withAlphaComponent(0.20).cgColor)
        NSColor(srgbRed: 0.91, green: 0.915, blue: 0.93, alpha: Theme.supportsLiquidGlass ? 0.55 : 0.94).setFill()
        disc.fill()
        context.restoreGState()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        disc.lineWidth = 1
        disc.stroke()

        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
        NSColor(srgbRed: 0.93, green: 0.935, blue: 0.95, alpha: 0.9).setFill()
        ring.fill()
    }

    private func drawLabel(_ item: RadialItem, start: CGFloat, end: CGFloat, highlighted: Bool, count: Int, slice: CGFloat) {
        let mid = (start + end) / 2
        let labelRadius = (innerRadius + outerRadius) / 2 + (item.icon == nil ? 0 : 2)
        let labelCenter = NSPoint(x: center.x + cos(mid) * labelRadius, y: center.y + sin(mid) * labelRadius)
        let fontSize: CGFloat
        switch count {
        case ...6: fontSize = item.icon == nil ? 17 : 13
        case 7...8: fontSize = item.icon == nil ? 15 : 12
        case 9...10: fontSize = item.icon == nil ? 13 : 10.5
        default: fontSize = item.icon == nil ? 11 : 9.5
        }
        let color = highlighted ? NSColor.white : ink
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .kern: item.icon == nil ? 0.2 : 0.4,
        ]
        let text = NSAttributedString(string: item.label, attributes: attributes)
        let size = text.size()
        var origin = NSPoint(x: labelCenter.x - size.width / 2, y: labelCenter.y - size.height / 2)
        if let icon = item.icon {
            let iconSize: CGFloat = count > 8 ? 18 : 24
            icon.draw(in: NSRect(x: labelCenter.x - iconSize / 2, y: labelCenter.y - 1, width: iconSize, height: iconSize), color: color)
            origin.y = labelCenter.y - size.height - 1
        }
        text.draw(at: origin)
    }

    private func drawPill(_ title: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: ink,
            .kern: 0.2,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        var size = text.size()
        size.width = min(size.width, innerRadius * 2 - 28)
        let pillWidth = max(size.width + 30, 72)
        let pillHeight: CGFloat = 36
        let rect = NSRect(x: center.x - pillWidth / 2, y: center.y - pillHeight / 2, width: pillWidth, height: pillHeight)
        let pill = NSBezierPath(roundedRect: rect, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.10).cgColor)
        NSColor.white.setFill()
        pill.fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
        text.draw(with: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawCaption(_ caption: String) {
        guard !caption.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: muted,
            .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: caption, attributes: attributes)
        let size = text.size()
        let width = min(size.width, discRadius * 2.4)
        let rect = NSRect(x: center.x - width / 2, y: center.y - discRadius - 12 - size.height, width: width, height: size.height)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setShadow(offset: .zero, blur: 6, color: NSColor.white.withAlphaComponent(0.9).cgColor)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        context?.restoreGState()
    }

    private func drawEmpty() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let title = NSAttributedString(string: emptyMessage, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: ink,
            .paragraphStyle: paragraph,
        ])
        let detail = NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: muted,
            .paragraphStyle: paragraph,
        ])
        let width = max(title.size().width, detail.size().width) + 44
        let height: CGFloat = subtitle.isEmpty ? 44 : 62
        let rect = NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let pill = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 0.97).setFill()
        pill.fill()
        context?.restoreGState()
        var y = rect.maxY - 12
        title.draw(with: NSRect(x: rect.minX, y: y - title.size().height, width: rect.width, height: title.size().height), options: [.usesLineFragmentOrigin])
        y -= title.size().height + 4
        if !subtitle.isEmpty {
            detail.draw(with: NSRect(x: rect.minX, y: y - detail.size().height, width: rect.width, height: detail.size().height), options: [.usesLineFragmentOrigin])
        }
    }

    func updateHighlight(forWindowPoint point: NSPoint) {
        highlighted = index(at: convert(point, from: nil))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        guard let highlighted, highlighted < items.count else {
            onCancel?()
            return false
        }
        let item = items[highlighted]
        DispatchQueue.main.async { [weak self] in self?.onSelect?(item) }
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
        if let highlighted, highlighted < items.count {
            onSelect?(items[highlighted])
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { return }
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            if let highlighted, highlighted < items.count { onSelect?(items[highlighted]) }
        case 123, 126:
            step(-1)
        case 124, 125:
            step(1)
        default:
            super.keyDown(with: event)
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = highlighted ?? -1
        var next = (current + delta) % items.count
        if next < 0 { next += items.count }
        highlighted = next
    }

    func clearHighlight() { highlighted = nil }

    func highlight(_ index: Int) {
        highlighted = items.indices.contains(index) ? index : nil
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
