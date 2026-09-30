import AppKit
import CoreGraphics

@MainActor
final class ScreenshotController {
    static let shared = ScreenshotController()

    private var overlays: [CaptureWindow] = []
    private var isCapturing = false

    private init() {}

    func startCapture() {
        NSLog("KShot 收到截图请求")
        guard !isCapturing else { return }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }

        let captures = NSScreen.screens.compactMap { screen -> (NSScreen, CGImage)? in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let image = CGDisplayCreateImage(CGDirectDisplayID(number.uint32Value))
            else { return nil }
            return (screen, image)
        }

        guard !captures.isEmpty else {
            showCaptureError()
            return
        }

        isCapturing = true
        NSApp.activate(ignoringOtherApps: true)
        overlays = captures.map { screen, image in
            let window = CaptureWindow(screen: screen, image: image)
            window.captureDidBegin = { [weak self, weak window] in
                guard let self, let activeWindow = window else { return }
                self.overlays.filter { $0 !== activeWindow }.forEach { $0.orderOut(nil) }
            }
            window.completion = { [weak self] result in
                self?.finish(with: result)
            }
            return window
        }
        overlays.forEach { $0.orderFrontRegardless() }
        overlays.first?.makeKey()
    }

    private func finish(with result: CaptureResult) {
        guard isCapturing else { return }
        isCapturing = false
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()

        if case let .completed(image) = result {
            copyToPasteboard(image)
            NSSound(named: "Tink")?.play()
        } else if case let .recognizeText(image) = result {
            Task { await recognizeText(in: image) }
        }
    }

    private func recognizeText(in image: NSImage) async {
        do {
            let text = try await ZhipuOCRService().recognize(image)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            NSSound(named: "Glass")?.play()
        } catch {
            showOCRError(error.localizedDescription)
        }
    }

    private func copyToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 KShot，然后重新截图。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showCaptureError() {
        let alert = NSAlert()
        alert.messageText = "无法读取屏幕"
        alert.informativeText = "请检查屏幕录制权限后重试。"
        alert.runModal()
    }

    private func showOCRError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "文字识别失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

enum CaptureResult {
    case completed(NSImage)
    case recognizeText(NSImage)
    case cancelled
}
