import AppKit

enum RadialAction: Hashable {
    case convert(FileFormat)
    case tool(ToolID)
}

struct RadialItem: Identifiable, Hashable {
    let action: RadialAction
    let label: String
    let detail: String
    let symbol: String?

    var id: RadialAction { action }

    init(format: FileFormat) {
        action = .convert(format)
        label = format.displayName
        detail = "Convert to \(format.displayName)"
        symbol = nil
    }

    init(tool: ToolID) {
        action = .tool(tool)
        label = tool.radialLabel
        detail = tool.title
        symbol = tool.symbol
    }
}

final class RadialView: NSView {
    var items: [RadialItem] = [] { didSet { needsDisplay = true } }
    var emptyMessage = "No conversions available"
    var subtitle = ""
    var center: NSPoint = .zero { didSet { needsDisplay = true } }
    var accent = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.15, alpha: 1)
    var onSelect: ((RadialItem) -> Void)?
    var onCancel: (() -> Void)?
    var interactive = false
    var advancedMode = false { didSet { needsDisplay = true } }

    private(set) var highlighted: Int? { didSet { if oldValue != highlighted { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    let innerRadius: CGFloat = 52
    let outerRadius: CGFloat = 138

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
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

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let count = items.count
        if count == 0 {
            drawCenter(title: emptyMessage, detail: subtitle)
            return
        }
        let gap: CGFloat = 0.018
        for index in 0..<count {
            let (start, end) = angles(for: index)
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: outerRadius, startAngle: (start + gap) * 180 / .pi, endAngle: (end - gap) * 180 / .pi)
            path.appendArc(withCenter: center, radius: innerRadius + 6, startAngle: (end - gap) * 180 / .pi, endAngle: (start + gap) * 180 / .pi, clockwise: true)
            path.close()

            let isHighlighted = highlighted == index
            let fill: NSColor
            if isHighlighted {
                fill = accent
            } else if advancedMode {
                fill = NSColor(calibratedWhite: 0.13, alpha: 0.94)
            } else {
                fill = NSColor(calibratedWhite: 0.11, alpha: 0.92)
            }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            fill.setFill()
            path.fill()
            context.restoreGState()
            NSColor.white.withAlphaComponent(isHighlighted ? 0.35 : 0.08).setStroke()
            path.lineWidth = 1
            path.stroke()

            let mid = (start + end) / 2
            let labelRadius = (innerRadius + outerRadius) / 2 + 4
            let labelCenter = NSPoint(x: center.x + cos(mid) * labelRadius, y: center.y + sin(mid) * labelRadius)
            let item = items[index]
            let fontSize: CGFloat = count > 8 ? 10 : 11.5
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: isHighlighted ? NSColor.black : NSColor.white,
                .kern: 0.6,
            ]
            let text = NSAttributedString(string: item.label, attributes: attributes)
            let size = text.size()
            var origin = NSPoint(x: labelCenter.x - size.width / 2, y: labelCenter.y - size.height / 2)
            if let symbolName = item.symbol, let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                let tinted = symbol.withSymbolConfiguration(config)?.tinted(isHighlighted ? .black : .white)
                let iconSize = NSSize(width: 16, height: 16)
                tinted?.draw(in: NSRect(x: labelCenter.x - iconSize.width / 2, y: labelCenter.y + 2, width: iconSize.width, height: iconSize.height))
                origin.y = labelCenter.y - size.height - 2
            }
            text.draw(at: origin)
        }

        let title: String
        let detail: String
        if let highlighted, highlighted < items.count {
            title = items[highlighted].detail
            detail = subtitle
        } else {
            title = advancedMode ? "Advanced tools" : "Convert formats"
            detail = subtitle
        }
        drawCenter(title: title, detail: detail)
    }

    private func drawCenter(title: String, detail: String) {
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
        NSColor(calibratedWhite: 0.06, alpha: 0.96).setFill()
        circle.fill()
        accent.withAlphaComponent(0.9).setStroke()
        circle.lineWidth = 2
        circle.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .paragraphStyle: paragraph,
        ]
        let box = NSRect(x: center.x - innerRadius + 8, y: center.y - innerRadius + 8, width: innerRadius * 2 - 16, height: innerRadius * 2 - 16)
        let titleString = NSAttributedString(string: title, attributes: titleAttributes)
        let detailString = NSAttributedString(string: detail, attributes: detailAttributes)
        let titleSize = titleString.boundingRect(with: NSSize(width: box.width, height: box.height), options: [.usesLineFragmentOrigin])
        let detailSize = detail.isEmpty ? .zero : detailString.boundingRect(with: NSSize(width: box.width, height: box.height), options: [.usesLineFragmentOrigin])
        let total = titleSize.height + (detail.isEmpty ? 0 : detailSize.height + 3)
        var y = center.y + total / 2
        titleString.draw(with: NSRect(x: box.minX, y: y - titleSize.height, width: box.width, height: titleSize.height), options: [.usesLineFragmentOrigin])
        y -= titleSize.height + 3
        if !detail.isEmpty {
            detailString.draw(with: NSRect(x: box.minX, y: y - detailSize.height, width: box.width, height: detailSize.height), options: [.usesLineFragmentOrigin])
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
