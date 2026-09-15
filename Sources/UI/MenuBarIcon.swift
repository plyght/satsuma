import AppKit

enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let body = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 0.5, width: 15, height: 15))
            body.lineWidth = 1.6
            NSColor.black.setStroke()
            body.stroke()
            for index in 0..<4 {
                let angle = CGFloat(index) * .pi / 4
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 9 + cos(angle) * 6.2, y: 8 + sin(angle) * 6.2))
                line.line(to: NSPoint(x: 9 - cos(angle) * 6.2, y: 8 - sin(angle) * 6.2))
                line.lineWidth = 1.1
                line.stroke()
            }
            let leaf = NSBezierPath()
            leaf.move(to: NSPoint(x: 9.5, y: 15.5))
            leaf.curve(to: NSPoint(x: 15, y: 17.5), controlPoint1: NSPoint(x: 10.5, y: 17.5), controlPoint2: NSPoint(x: 13, y: 18))
            leaf.curve(to: NSPoint(x: 9.5, y: 15.5), controlPoint1: NSPoint(x: 14.5, y: 15.5), controlPoint2: NSPoint(x: 11.5, y: 14.5))
            NSColor.black.setFill()
            leaf.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
