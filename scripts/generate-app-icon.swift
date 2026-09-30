import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("用法：swift scripts/generate-app-icon.swift <输入 PNG> <输出 ICNS>\n", stderr)
    exit(1)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let sourceImage = NSImage(contentsOf: inputURL) else {
    fputs("无法读取输入图片：\(inputURL.path)\n", stderr)
    exit(1)
}

let fileManager = FileManager.default
let temporaryRoot = fileManager.temporaryDirectory
    .appendingPathComponent("KShot-AppIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporaryRoot) }

let representations: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for representation in representations {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: representation.pixels,
        pixelsHigh: representation.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "KShotIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建图标位图"])
    }

    bitmap.size = NSSize(width: representation.pixels, height: representation.pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: representation.pixels, height: representation.pixels).fill()
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: representation.pixels, height: representation.pixels),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "KShotIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法编码图标 PNG"])
    }
    try png.write(to: iconsetURL.appendingPathComponent(representation.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

print("已生成：\(outputURL.path)")
