import XCTest
import AppKit
@testable import KShot

final class GeometryTests: XCTestCase {
    func testRectFromTwoPointsIsStandardized() {
        let rect = CGRect(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 5, y: 10))
        XCTAssertEqual(rect, CGRect(x: 5, y: 10, width: 15, height: 20))
    }

    func testResizeHandlePoints() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 60)
        XCTAssertEqual(rect.point(for: .topLeft), CGPoint(x: 10, y: 20))
        XCTAssertEqual(rect.point(for: .bottomRight), CGPoint(x: 110, y: 80))
        XCTAssertEqual(rect.point(for: .right), CGPoint(x: 110, y: 50))
    }

    func testPaddleOCRCTCDecoderRemovesBlankAndDuplicates() throws {
        let decoder = PaddleOCRDecoder(characters: ["你", "好"])
        let values: [Float] = [
            0.1, 0.9, 0.0, 0.0,
            0.1, 0.8, 0.1, 0.0,
            0.9, 0.1, 0.0, 0.0,
            0.1, 0.0, 0.9, 0.0
        ]
        XCTAssertEqual(try decoder.decode(values, shape: [1, 4, 4]), "你好")
    }

    @MainActor
    func testBundledPaddleOCRRecognizesRenderedText() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = repository.appendingPathComponent("Resources/PaddleOCR")
        let service = PaddleOCRService(
            modelURL: resources.appendingPathComponent("PP-OCRv6_tiny_rec.onnx"),
            dictionaryURL: resources.appendingPathComponent("character_dict.txt")
        )
        let englishImage = NSImage(size: NSSize(width: 720, height: 96))
        englishImage.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: englishImage.size).fill()
        "KShot 123".draw(
            at: NSPoint(x: 20, y: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 54, weight: .medium),
                .foregroundColor: NSColor.black
            ]
        )
        englishImage.unlockFocus()

        let text = try await service.recognize(englishImage)
        XCTAssertEqual(
            text.replacingOccurrences(of: " ", with: "").lowercased(),
            "kshot123"
        )

        let chineseImage = NSImage(size: NSSize(width: 720, height: 96))
        chineseImage.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: chineseImage.size).fill()
        "截图文字 2026".draw(
            at: NSPoint(x: 20, y: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 54, weight: .medium),
                .foregroundColor: NSColor.black
            ]
        )
        chineseImage.unlockFocus()

        let chineseText = try await service.recognize(chineseImage)
        XCTAssertEqual(chineseText.replacingOccurrences(of: " ", with: ""), "截图文字2026")
    }
}
