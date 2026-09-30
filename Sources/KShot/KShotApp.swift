import AppKit
import Carbon.HIToolbox

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let retainedDelegate = AppDelegate()
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?

    static func main() {
        let application = NSApplication.shared
        application.delegate = retainedDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        hotKeyManager = HotKeyManager(keyCode: UInt32(kVK_ANSI_A), identifierID: 1) {
            ScreenshotController.shared.startCapture()
        }
        Task.detached(priority: .utility) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                try await PaddleOCRService.shared.prepare()
                NSLog("PaddleOCR 本地模型已就绪，耗时 %.3f 秒", CFAbsoluteTimeGetCurrent() - startedAt)
            } catch {
                NSLog("PaddleOCR 本地模型加载失败：%@", error.localizedDescription)
            }
        }
        NSLog("KShot 已启动，快捷键注册状态：%@", hotKeyManager?.isRegistered == true ? "成功" : "失败")
        if CommandLine.arguments.contains("--capture-on-launch") {
            DispatchQueue.main.async {
                ScreenshotController.shared.startCapture()
            }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "KShot")
        item.button?.toolTip = "KShot 截图"

        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "截图  ⌃⌘A", action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 KShot", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出 KShot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func startCapture() {
        ScreenshotController.shared.startCapture()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "KShot",
            .applicationVersion: "0.3.1",
            .credits: NSAttributedString(string: "作者：范显")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
