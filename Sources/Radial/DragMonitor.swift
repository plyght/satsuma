import AppKit

protocol DragMonitorDelegate: AnyObject {
    func dragMonitor(_ monitor: DragMonitor, didBeginModifiedDrag urls: [URL], at point: NSPoint, advanced: Bool)
    func dragMonitor(_ monitor: DragMonitor, didChangeModifiers shift: Bool, option: Bool, at point: NSPoint)
    func dragMonitorDidEndDrag(_ monitor: DragMonitor)
}

final class DragMonitor {
    weak var delegate: DragMonitorDelegate?

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var lastPasteboardChange = NSPasteboard(name: .drag).changeCount
    private var activeURLs: [URL] = []
    private var presenting = false
    private var mouseDown = false

    func start() {
        stop()
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            self?.handleDragged(event)
        }
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.mouseDown = true
            self?.activeURLs = []
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.finishDrag()
        }
        let flags = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] _ in
            self?.evaluateModifiers()
        }
        monitors = [dragged, down, up, flags].compactMap { $0 }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollDragSession()
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private var currentModifiers: (shift: Bool, option: Bool) {
        let flags = NSEvent.modifierFlags
        return (flags.contains(.shift), flags.contains(.option))
    }

    private func handleDragged(_ event: NSEvent) {
        mouseDown = true
        refreshURLsIfNeeded()
        evaluateModifiers()
    }

    private func pollDragSession() {
        guard mouseDown || NSEvent.pressedMouseButtons & 1 == 1 else {
            if presenting { finishDrag() }
            return
        }
        refreshURLsIfNeeded()
        evaluateModifiers()
    }

    private func refreshURLsIfNeeded() {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pasteboard.changeCount
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        activeURLs = urls.filter { url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }
    }

    private func evaluateModifiers() {
        guard !activeURLs.isEmpty, NSEvent.pressedMouseButtons & 1 == 1 else {
            if presenting, NSEvent.pressedMouseButtons & 1 == 0 { finishDrag() }
            return
        }
        let mods = currentModifiers
        let point = NSEvent.mouseLocation
        if mods.shift, !presenting {
            presenting = true
            delegate?.dragMonitor(self, didBeginModifiedDrag: activeURLs, at: point, advanced: mods.option)
        } else if presenting {
            delegate?.dragMonitor(self, didChangeModifiers: mods.shift, option: mods.option, at: point)
        }
    }

    private func finishDrag() {
        mouseDown = false
        activeURLs = []
        if presenting {
            presenting = false
            delegate?.dragMonitorDidEndDrag(self)
        }
    }

    func markHandled() {
        presenting = false
        activeURLs = []
        mouseDown = false
    }
}
