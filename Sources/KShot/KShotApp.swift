import AppKit
import SwiftUI

@main
struct KShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("KShot", systemImage: "viewfinder") {
            Button("截图  ⌃⌘A") {
                ScreenshotController.shared.startCapture()
            }
            .keyboardShortcut("a", modifiers: [.control, .command])

            Divider()

            Button("关于 KShot") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "KShot",
                    .applicationVersion: "0.1.0",
                    .credits: NSAttributedString(string: "作者：范显")
                ])
            }

            Button("退出") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hotKeyManager = HotKeyManager {
            ScreenshotController.shared.startCapture()
        }
    }
}
