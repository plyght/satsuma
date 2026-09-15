import AppKit
import SwiftUI

@main
struct SatsumaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppSettings.shared)
        }
    }
}
