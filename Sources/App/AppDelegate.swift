import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let dragMonitor = DragMonitor()
    private let radial = RadialController()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppSettings.shared.applyAppearance()
        installStatusItem()
        if ScreenshotDriver.isEnabled {
            ScreenshotDriver.run(radial: radial)
            return
        }
        dragMonitor.delegate = radial
        dragMonitor.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        radial.presentPicker(for: urls)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Satsuma")
            button.toolTip = "Satsuma: hold Shift while dragging a file"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Convert Files…", action: #selector(convertFiles), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Open Tool for Files…", action: #selector(openTool), keyEquivalent: "t").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About Satsuma", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Satsuma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func convertFiles() {
        pickFiles { [weak self] urls in self?.radial.presentPicker(for: urls, advanced: false) }
    }

    @objc private func openTool() {
        pickFiles { [weak self] urls in self?.radial.presentPicker(for: urls, advanced: true) }
    }

    private func pickFiles(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            completion(panel.urls)
        }
    }

    static func makeSettingsWindow() -> NSWindow {
        let view = SettingsView().environmentObject(AppSettings.shared)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = "Satsuma Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 640))
        window.center()
        return window
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.makeSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Satsuma",
            .applicationVersion: "0.1.0",
            .credits: NSAttributedString(string: "The zero-click offline file converter.\nEverything happens locally on your Mac."),
        ])
    }
}
