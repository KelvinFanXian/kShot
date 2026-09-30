import AppKit
import Carbon.HIToolbox

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let retainedDelegate = AppDelegate()
    private var statusItem: NSStatusItem?
    private var hotKeyManagers: [HotKeyManager] = []

    static func main() {
        let application = NSApplication.shared
        application.delegate = retainedDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        hotKeyManagers = [
            HotKeyManager(keyCode: UInt32(kVK_ANSI_A), identifierID: 1) {
                ScreenshotController.shared.startCapture()
            },
            HotKeyManager(keyCode: UInt32(kVK_ANSI_X), identifierID: 2) {
                ScreenshotController.shared.startTextCapture()
            }
        ]
        NSLog("KShot 已启动，快捷键注册状态：%@", hotKeyManagers.allSatisfy(\.isRegistered) ? "成功" : "失败")
        if CommandLine.arguments.contains("--text-capture-on-launch") {
            DispatchQueue.main.async {
                ScreenshotController.shared.startTextCapture()
            }
        } else if CommandLine.arguments.contains("--capture-on-launch") {
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

        let textCaptureItem = NSMenuItem(title: "划词识别  ⌃⌘X", action: #selector(startTextCapture), keyEquivalent: "")
        textCaptureItem.target = self
        menu.addItem(textCaptureItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 KShot", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let ocrSettingsItem = NSMenuItem(title: "智谱 OCR 设置…", action: #selector(configureOCR), keyEquivalent: "")
        ocrSettingsItem.target = self
        menu.addItem(ocrSettingsItem)

        let quitItem = NSMenuItem(title: "退出 KShot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func startCapture() {
        ScreenshotController.shared.startCapture()
    }

    @objc private func startTextCapture() {
        ScreenshotController.shared.startTextCapture()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "KShot",
            .applicationVersion: "0.2.1",
            .credits: NSAttributedString(string: "作者：范显")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func configureOCR() {
        let alert = NSAlert()
        alert.messageText = "智谱 OCR 设置"
        alert.informativeText = "Coding Plan Key 仅保存在本机钥匙串中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = APIKeyStore.shared.load() == nil ? "输入 Coding Plan Key" : "已设置；输入新 Key 可替换"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if APIKeyStore.shared.save(field.stringValue) {
            let confirmation = NSAlert()
            confirmation.messageText = "已保存"
            confirmation.informativeText = "智谱 Coding Plan Key 已安全存入本机钥匙串。"
            confirmation.runModal()
        } else {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "保存失败"
            failure.informativeText = "请输入有效的 Coding Plan Key 后重试。"
            failure.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
