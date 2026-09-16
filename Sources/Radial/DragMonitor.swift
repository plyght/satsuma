import AppKit

protocol DragMonitorDelegate: AnyObject {
    func dragMonitor(_ monitor: DragMonitor, didBeginModifiedDrag urls: [URL], at point: NSPoint, advanced: Bool)
    func dragMonitor(_ monitor: DragMonitor, didChangeModifiers shift: Bool, option: Bool, at point: NSPoint)
    func dragMonitor(_ monitor: DragMonitor, didUpdateDraggedURLs urls: [URL])
    func dragMonitorDidEndDrag(_ monitor: DragMonitor)
}

enum DragDebug {
    static let enabled = ProcessInfo.processInfo.environment["SATSUMA_DEBUG_DRAG"] != nil
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let path = ProcessInfo.processInfo.environment["SATSUMA_DEBUG_DRAG"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/tmp/satsuma-drag.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled, let handle else { return }
        handle.write(Data((String(format: "%.3f ", Date().timeIntervalSince1970) + message() + "\n").utf8))
    }
}

final class DragMonitor {
    weak var delegate: DragMonitorDelegate?

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var activity: NSObjectProtocol?
    private var pressChangeCount = 0
    private var lastReadChange = 0
    private var activeURLs: [URL] = []
    private var dragInFlight = false
    private var presenting = false
    private var handled = false
    private var mouseDown = false
    private var pressOrigin = NSPoint.zero
    private var pressTime = Date.distantPast
    private var pressInFinder = false
    private var pollTick = 0

    private static let idleInterval = 1.0 / 30.0
    private static let dragInterval = 1.0 / 60.0
    private static let fallbackDragDistance: CGFloat = 24
    private static let fallbackDelay: TimeInterval = 0.3

    func start() {
        stop()
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            self?.beginPressIfNeeded()
            self?.poll()
        }
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            DragDebug.log("global leftMouseDown flags=\(event.modifierFlags.rawValue)")
            self?.beginPressIfNeeded()
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DragDebug.log("global leftMouseUp")
            self?.finishPress()
        }
        monitors = [dragged, down, up].compactMap { $0 }
        schedulePoll(interval: Self.idleInterval)
        DragDebug.log("DragMonitor started; monitors=\(monitors.count) dragChangeCount=\(NSPasteboard(name: .drag).changeCount)")
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        endActivity()
    }

    func markHandled() {
        handled = true
        presenting = false
        activeURLs = []
    }

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private var buttonPressed: Bool { NSEvent.pressedMouseButtons & 1 == 1 }

    private var currentModifiers: (shift: Bool, option: Bool) {
        let flags = NSEvent.modifierFlags
        return (flags.contains(.shift), flags.contains(.option))
    }

    private func beginPressIfNeeded() {
        guard !mouseDown else { return }
        mouseDown = true
        handled = false
        dragInFlight = false
        activeURLs = []
        pressOrigin = NSEvent.mouseLocation
        pressTime = Date()
        pressInFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        pressChangeCount = NSPasteboard(name: .drag).changeCount
        lastReadChange = pressChangeCount
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Tracking a file drag")
        schedulePoll(interval: Self.dragInterval)
        DragDebug.log("press began at \(NSEvent.mouseLocation) dragChangeCount=\(pressChangeCount) flags=\(NSEvent.modifierFlags.rawValue)")
    }

    private func poll() {
        guard buttonPressed else {
            if mouseDown { finishPress() }
            return
        }
        beginPressIfNeeded()
        refreshDragPasteboard()
        if !dragInFlight, pressInFinder, currentModifiers.shift, Date().timeIntervalSince(pressTime) >= Self.fallbackDelay, hypot(NSEvent.mouseLocation.x - pressOrigin.x, NSEvent.mouseLocation.y - pressOrigin.y) >= Self.fallbackDragDistance {
            dragInFlight = true
            DragDebug.log("no drag pasteboard content; assuming Finder drag from movement")
        }
        evaluateModifiers()
        pollTick += 1
        if pollTick % 30 == 0 {
            DragDebug.log("poll: loc=\(NSEvent.mouseLocation) shift=\(currentModifiers.shift) option=\(currentModifiers.option) inFlight=\(dragInFlight) urls=\(activeURLs.count) presenting=\(presenting) handled=\(handled)")
        }
    }

    private func refreshDragPasteboard() {
        let pasteboard = NSPasteboard(name: .drag)
        let change = pasteboard.changeCount
        guard change != lastReadChange else { return }
        lastReadChange = change
        guard change > pressChangeCount else { return }
        let items = pasteboard.pasteboardItems ?? []
        dragInFlight = !items.isEmpty
        activeURLs = Self.fileURLs(on: pasteboard)
        DragDebug.log("drag pasteboard change=\(change) types=\(pasteboard.types?.map(\.rawValue) ?? []) items=\(items.count) itemTypes=\(items.map { $0.types.map(\.rawValue) }) urls=\(activeURLs.map(\.path))")
        if presenting, !activeURLs.isEmpty {
            delegate?.dragMonitor(self, didUpdateDraggedURLs: activeURLs)
        }
    }

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty {
            urls = (pasteboard.pasteboardItems ?? []).compactMap { item in
                item.string(forType: .fileURL).flatMap { URL(string: $0) }
            }
        }
        return urls.compactMap { url -> URL? in
            let resolved = (url as NSURL).filePathURL ?? url
            guard resolved.isFileURL else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return resolved.standardizedFileURL
        }
    }

    private func evaluateModifiers() {
        guard mouseDown, dragInFlight, !handled else { return }
        let mods = currentModifiers
        let point = NSEvent.mouseLocation
        if mods.shift, !presenting {
            presenting = true
            DragDebug.log("presenting wheel for \(activeURLs.map(\.lastPathComponent)) at \(point) option=\(mods.option)")
            delegate?.dragMonitor(self, didBeginModifiedDrag: activeURLs, at: point, advanced: mods.option)
        } else if presenting {
            delegate?.dragMonitor(self, didChangeModifiers: mods.shift, option: mods.option, at: point)
        }
    }

    private func finishPress() {
        guard mouseDown else { return }
        mouseDown = false
        dragInFlight = false
        handled = false
        activeURLs = []
        endActivity()
        schedulePoll(interval: Self.idleInterval)
        if presenting {
            presenting = false
            DragDebug.log("press ended; dismissing wheel")
            delegate?.dragMonitorDidEndDrag(self)
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
