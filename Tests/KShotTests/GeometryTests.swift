import XCTest
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

    func testOCRResponseRemovesMarkdownFence() {
        XCTAssertEqual(ZhipuOCRService.cleaned("```text\n第一行\n第二行\n```"), "第一行\n第二行")
        XCTAssertEqual(ZhipuOCRService.cleaned("  普通文本  "), "普通文本")
    }
}
