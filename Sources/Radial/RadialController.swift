import AppKit

final class RadialPanel: NSPanel {
    let radialView = RadialView(frame: .zero)

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        radialView.frame = contentView?.bounds ?? .zero
        radialView.autoresizingMask = [.width, .height]
        contentView = radialView
    }

    override var canBecomeKey: Bool { true }
}

final class RadialController: DragMonitorDelegate {
    private var panel: RadialPanel?
    private var urls: [URL] = []
    private var formats: [FileFormat] = []
    private var advanced = false
    private var visible = false
    private var pickerMode = false
    private var outsideClickMonitor: Any?

    weak var dragMonitor: DragMonitor?

    func dragMonitor(_ monitor: DragMonitor, didBeginModifiedDrag urls: [URL], at point: NSPoint, advanced: Bool) {
        dragMonitor = monitor
        pickerMode = false
        present(urls: urls, at: point, advanced: advanced)
    }

    func dragMonitor(_ monitor: DragMonitor, didChangeModifiers shift: Bool, option: Bool, at point: NSPoint) {
        guard !pickerMode else { return }
        if !shift {
            if visible { hide() }
            return
        }
        if !visible {
            present(urls: urls, at: point, advanced: option)
            return
        }
        if option != advanced {
            advanced = option
            reloadItems()
        }
    }

    func dragMonitorDidEndDrag(_ monitor: DragMonitor) {
        guard !pickerMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.pickerMode else { return }
            self.hide()
        }
    }

    func presentPicker(for urls: [URL], advanced: Bool = false) {
        pickerMode = true
        let point = NSEvent.mouseLocation
        present(urls: urls, at: point, advanced: advanced)
        panel?.radialView.interactive = true
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panel?.radialView)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitor()
    }

    private func present(urls: [URL], at point: NSPoint, advanced: Bool) {
        self.urls = urls
        self.advanced = advanced
        formats = urls.compactMap(FileFormat.detect)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = self.panel ?? RadialPanel(screen: screen)
        panel.setFrame(screen.frame, display: false)
        self.panel = panel

        let view = panel.radialView
        view.interactive = pickerMode
        view.advancedMode = advanced
        let clamped = clampedCenter(point, in: screen.frame, radius: view.outerRadius + 20)
        view.center = NSPoint(x: clamped.x - screen.frame.minX, y: clamped.y - screen.frame.minY)
        view.onSelect = { [weak self] item in self?.select(item) }
        view.onCancel = { [weak self] in self?.hide() }
        view.clearHighlight()
        reloadItems()
        panel.orderFrontRegardless()
        visible = true
    }

    private func clampedCenter(_ point: NSPoint, in frame: NSRect, radius: CGFloat) -> NSPoint {
        NSPoint(
            x: min(max(point.x, frame.minX + radius), frame.maxX - radius),
            y: min(max(point.y, frame.minY + radius), frame.maxY - radius)
        )
    }

    private func reloadItems() {
        guard let view = panel?.radialView else { return }
        view.advancedMode = advanced
        let count = urls.count
        view.subtitle = count == 1 ? urls[0].lastPathComponent : "\(count) files"
        if formats.count != urls.count {
            view.items = []
            view.emptyMessage = "Unsupported file type"
            return
        }
        if advanced {
            view.items = ToolID.available(for: formats).map(RadialItem.init(tool:))
            view.emptyMessage = "No tools for this selection"
        } else {
            view.items = ConversionMatrix.targets(for: formats).map(RadialItem.init(format:))
            view.emptyMessage = "No conversions available"
        }
    }

    private func select(_ item: RadialItem) {
        let selectedURLs = urls
        hide()
        dragMonitor?.markHandled()
        Task { @MainActor in
            switch item.action {
            case .convert(let target):
                JobRunner.shared.convert(selectedURLs, to: target)
            case .tool(let tool):
                ToolWindowManager.shared.open(tool, files: selectedURLs)
            }
        }
    }

    func hide() {
        visible = false
        pickerMode = false
        panel?.radialView.clearHighlight()
        panel?.radialView.interactive = false
        panel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func installOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }
}
