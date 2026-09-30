import AppKit

enum AnnotationTool: CaseIterable {
    case rectangle
    case arrow
    case text
    case mosaic

    var symbolName: String {
        switch self {
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3.fill"
        }
    }

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .text: "文字"
        case .mosaic: "马赛克"
        }
    }
}

enum Annotation {
    case rectangle(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case text(String, at: CGPoint)
    case mosaic([CGPoint])
}

enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

extension CGRect {
    init(from start: CGPoint, to end: CGPoint) {
        self.init(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    func point(for handle: ResizeHandle) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: minX, y: minY)
        case .top: CGPoint(x: midX, y: minY)
        case .topRight: CGPoint(x: maxX, y: minY)
        case .right: CGPoint(x: maxX, y: midY)
        case .bottomRight: CGPoint(x: maxX, y: maxY)
        case .bottom: CGPoint(x: midX, y: maxY)
        case .bottomLeft: CGPoint(x: minX, y: maxY)
        case .left: CGPoint(x: minX, y: midY)
        }
    }
}
