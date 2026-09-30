import AppKit

final class CaptureWindow: NSWindow {
    var completion: ((CaptureResult) -> Void)? { didSet { captureView.completion = completion } }
    var captureDidBegin: (() -> Void)? { didSet { captureView.captureDidBegin = captureDidBegin } }

    private let captureView: CaptureView

    init(screen: NSScreen, image: CGImage, mode: CaptureMode) {
        captureView = CaptureView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image, mode: mode)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = captureView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum Interaction {
    case idle, selecting, drawing
    case moving(origin: CGRect)
    case resizing(handle: ResizeHandle, origin: CGRect)
}

final class CaptureView: NSView, NSTextFieldDelegate {
    var completion: ((CaptureResult) -> Void)?
    var captureDidBegin: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private let sourceImage: NSImage
    private let pixelatedImage: NSImage
    private let mode: CaptureMode
    private var selection: CGRect = .zero
    private var interaction: Interaction = .idle
    private var dragStart: CGPoint = .zero
    private var currentPoint: CGPoint = .zero
    private var selectedTool: AnnotationTool?
    private var annotations: [Annotation] = []
    private var draftMosaic: [CGPoint] = []
    private var textEditor: NSTextField?
    private var hasAnnouncedCapture = false
    private var isFinishing = false
    private let buttonSize: CGFloat = 34
    private let buttonSpacing: CGFloat = 6
    private let toolbarPadding: CGFloat = 7

    init(frame: CGRect, image: CGImage, mode: CaptureMode) {
        sourceImage = NSImage(cgImage: image, size: frame.size)
        pixelatedImage = CaptureView.makePixelatedImage(from: image, displaySize: frame.size)
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawScreenImage(sourceImage)
        NSColor.black.withAlphaComponent(0.46).setFill()
        bounds.fill()
        guard selection.width >= 1, selection.height >= 1 else { drawHint(); return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        drawScreenImage(sourceImage)
        drawAnnotations()
        drawDraft()
        NSGraphicsContext.restoreGraphicsState()
        drawSelectionChrome()
        drawDimensionLabel()
        if case .selecting = interaction { return }
        drawToolbar()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if event.clickCount == 2, selection.contains(point), selectedTool != .text { completeCapture(); return }
        if !selection.isEmpty, toolbarRect.contains(point) { handleToolbarClick(at: point); return }
        announceCaptureIfNeeded()
        dragStart = point
        currentPoint = point

        if !selection.isEmpty, let handle = resizeHandle(at: point) {
            interaction = .resizing(handle: handle, origin: selection)
        } else if !selection.isEmpty, selection.contains(point), let selectedTool {
            switch selectedTool {
            case .text: beginTextEditing(at: point); interaction = .idle
            case .mosaic: draftMosaic = [clamped(point)]; interaction = .drawing
            case .rectangle, .arrow: interaction = .drawing
            }
        } else if !selection.isEmpty, selection.contains(point) {
            interaction = .moving(origin: selection)
        } else {
            commitTextEditor()
            annotations.removeAll()
            selection = CGRect(origin: point, size: .zero)
            interaction = .selecting
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentPoint = point
        switch interaction {
        case .selecting:
            selection = CGRect(from: dragStart, to: point).intersection(bounds)
        case let .moving(origin):
            let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
            var moved = origin.offsetBy(dx: delta.x, dy: delta.y)
            moved.origin.x = min(max(0, moved.origin.x), bounds.width - moved.width)
            moved.origin.y = min(max(0, moved.origin.y), bounds.height - moved.height)
            selection = moved
        case let .resizing(handle, origin):
            selection = resizedRect(origin, handle: handle, to: point).intersection(bounds)
        case .drawing:
            if selectedTool == .mosaic { draftMosaic.append(clamped(point)) }
        case .idle: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        let shouldAutoRecognize: Bool
        if case .selecting = interaction {
            shouldAutoRecognize = mode == .textRecognition
        } else {
            shouldAutoRecognize = false
        }
        switch interaction {
        case .selecting, .moving, .resizing:
            selection = selection.standardized.integral
            if selection.width < 3 || selection.height < 3 { selection = .zero }
        case .drawing: commitDraftAnnotation()
        case .idle: break
        }
        interaction = .idle
        needsDisplay = true
        if shouldAutoRecognize, selection.width >= 3, selection.height >= 3 {
            recognizeText()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: finish(.cancelled)
        case 36, 76: completeCapture()
        case 51:
            if !annotations.isEmpty { annotations.removeLast(); needsDisplay = true }
        default: super.keyDown(with: event)
        }
    }

    private func announceCaptureIfNeeded() {
        guard !hasAnnouncedCapture else { return }
        hasAnnouncedCapture = true
        captureDidBegin?()
    }

    private func handleToolbarClick(at point: CGPoint) {
        for tool in AnnotationTool.allCases where toolButtonRect(tool).contains(point) {
            selectedTool = selectedTool == tool ? nil : tool
            needsDisplay = true
            return
        }
        if ocrButtonRect.contains(point) { recognizeText() }
        else if cancelButtonRect.contains(point) { finish(.cancelled) }
        else if doneButtonRect.contains(point) { completeCapture() }
    }

    private func completeCapture() {
        commitTextEditor()
        guard selection.width >= 3, selection.height >= 3, let image = renderSelection(includeAnnotations: true) else { return }
        finish(.completed(image))
    }

    private func recognizeText() {
        commitTextEditor()
        guard selection.width >= 3, selection.height >= 3,
              let image = renderSelection(includeAnnotations: false) else { return }
        finish(.recognizeText(image))
    }

    private func finish(_ result: CaptureResult) {
        guard !isFinishing else { return }
        isFinishing = true
        DispatchQueue.main.async { [weak self] in
            self?.completion?(result)
        }
    }

    private func commitDraftAnnotation() {
        guard selection.contains(dragStart) else { return }
        let end = clamped(currentPoint)
        switch selectedTool {
        case .rectangle:
            let rect = CGRect(from: dragStart, to: end)
            if rect.width > 2, rect.height > 2 { annotations.append(.rectangle(rect)) }
        case .arrow:
            if hypot(end.x - dragStart.x, end.y - dragStart.y) > 3 { annotations.append(.arrow(from: dragStart, to: end)) }
        case .mosaic:
            if draftMosaic.count > 1 { annotations.append(.mosaic(draftMosaic)) }
            draftMosaic.removeAll()
        case .text, .none: break
        }
    }

    private func beginTextEditing(at point: CGPoint) {
        commitTextEditor()
        let editor = NSTextField(frame: CGRect(x: point.x, y: point.y, width: 180, height: 28))
        editor.placeholderString = "输入文字，回车完成"
        editor.font = .systemFont(ofSize: 18, weight: .semibold)
        editor.textColor = .systemRed
        editor.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        editor.isBordered = false
        editor.focusRingType = .none
        editor.delegate = self
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditor() }

    private func commitTextEditor() {
        guard let editor = textEditor else { return }
        let text = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { annotations.append(.text(text, at: editor.frame.origin)) }
        editor.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(selection.minX, point.x), selection.maxX), y: min(max(selection.minY, point.y), selection.maxY))
    }

    private func resizedRect(_ original: CGRect, handle: ResizeHandle, to point: CGPoint) -> CGRect {
        var left = original.minX, right = original.maxX, top = original.minY, bottom = original.maxY
        switch handle {
        case .topLeft: left = point.x; top = point.y
        case .top: top = point.y
        case .topRight: right = point.x; top = point.y
        case .right: right = point.x
        case .bottomRight: right = point.x; bottom = point.y
        case .bottom: bottom = point.y
        case .bottomLeft: left = point.x; bottom = point.y
        case .left: left = point.x
        }
        return CGRect(from: CGPoint(x: left, y: top), to: CGPoint(x: right, y: bottom))
    }

    private func resizeHandle(at point: CGPoint) -> ResizeHandle? {
        ResizeHandle.allCases.first {
            let center = selection.point(for: $0)
            return CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14).contains(point)
        }
    }

    private func drawHint() {
        let text = mode == .textRecognition
            ? "拖过文字，松手识别并复制  ·  Esc 取消"
            : "拖动鼠标选择区域  ·  Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let rect = CGRect(x: bounds.midX - size.width / 2 - 14, y: 30, width: size.width + 28, height: 36)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: rect.minX + 14, y: rect.minY + 9), withAttributes: attrs)
    }

    private func drawSelectionChrome() {
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1.5
        border.stroke()
        for handle in ResizeHandle.allCases {
            let point = selection.point(for: handle)
            let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill(); NSBezierPath(rect: rect).fill()
            NSColor.systemBlue.setStroke(); NSBezierPath(rect: rect).stroke()
        }
    }

    private func drawDimensionLabel() {
        let scale = window?.backingScaleFactor ?? 1
        let text = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let y = selection.minY > 28 ? selection.minY - 25 : selection.minY + 7
        let rect = CGRect(x: selection.minX, y: y, width: size.width + 12, height: 20)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), withAttributes: attrs)
    }

    private func drawToolbar() {
        let rect = toolbarRect
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).stroke()
        for tool in AnnotationTool.allCases { drawButton(rect: toolButtonRect(tool), symbol: tool.symbolName, selected: tool == selectedTool) }
        drawButton(rect: ocrButtonRect, symbol: "text.viewfinder", color: .systemBlue)
        drawButton(rect: cancelButtonRect, symbol: "xmark", color: .secondaryLabelColor)
        drawButton(rect: doneButtonRect, symbol: "checkmark", color: .systemGreen)
    }

    private func drawButton(rect: CGRect, symbol: String, selected: Bool = false, color: NSColor = .labelColor) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let configured = image.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? image
        color.set()
        configured.draw(in: CGRect(x: rect.midX - 9, y: rect.midY - 9, width: 18, height: 18))
    }

    private var toolbarRect: CGRect {
        let count = CGFloat(AnnotationTool.allCases.count + 3)
        let width = toolbarPadding * 2 + count * buttonSize + (count - 1) * buttonSpacing
        var x = min(max(8, selection.maxX - width), bounds.width - width - 8)
        if bounds.width < width + 16 { x = 0 }
        var y = selection.maxY + 8
        if y + buttonSize + toolbarPadding * 2 > bounds.height { y = selection.maxY - buttonSize - toolbarPadding * 2 - 8 }
        return CGRect(x: x, y: y, width: width, height: buttonSize + toolbarPadding * 2)
    }

    private func toolButtonRect(_ tool: AnnotationTool) -> CGRect { buttonRect(index: AnnotationTool.allCases.firstIndex(of: tool) ?? 0) }
    private var ocrButtonRect: CGRect { buttonRect(index: AnnotationTool.allCases.count) }
    private var cancelButtonRect: CGRect { buttonRect(index: AnnotationTool.allCases.count + 1) }
    private var doneButtonRect: CGRect { buttonRect(index: AnnotationTool.allCases.count + 2) }
    private func buttonRect(index: Int) -> CGRect {
        CGRect(x: toolbarRect.minX + toolbarPadding + CGFloat(index) * (buttonSize + buttonSpacing), y: toolbarRect.minY + toolbarPadding, width: buttonSize, height: buttonSize)
    }

    private func drawAnnotations() { annotations.forEach(drawAnnotation) }

    private func drawDraft() {
        guard case .drawing = interaction else { return }
        switch selectedTool {
        case .rectangle: drawAnnotation(.rectangle(CGRect(from: dragStart, to: clamped(currentPoint))))
        case .arrow: drawAnnotation(.arrow(from: dragStart, to: clamped(currentPoint)))
        case .mosaic: drawAnnotation(.mosaic(draftMosaic))
        case .text, .none: break
        }
    }

    private func drawAnnotation(_ annotation: Annotation) {
        switch annotation {
        case let .rectangle(rect):
            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: rect); path.lineWidth = 3; path.stroke()
        case let .arrow(from, to): drawArrow(from: from, to: to)
        case let .text(text, point):
            text.draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.systemRed, .strokeColor: NSColor.white.withAlphaComponent(0.7), .strokeWidth: -1.5])
        case let .mosaic(points):
            guard points.count > 1 else { return }
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = 20; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.addClip()
            NSGraphicsContext.current?.imageInterpolation = .none
            drawScreenImage(pixelatedImage, interpolation: .none)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint) {
        let angle = atan2(to.y - from.y, to.x - from.x), length: CGFloat = 13, spread: CGFloat = .pi / 7
        let path = NSBezierPath(); path.move(to: from); path.line(to: to); path.move(to: to)
        path.line(to: CGPoint(x: to.x - length * cos(angle - spread), y: to.y - length * sin(angle - spread))); path.move(to: to)
        path.line(to: CGPoint(x: to.x - length * cos(angle + spread), y: to.y - length * sin(angle + spread)))
        path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor.systemRed.setStroke(); path.stroke()
    }

    private func renderSelection(includeAnnotations: Bool) -> NSImage? {
        let scaleX = CGFloat(sourceImage.representations.first?.pixelsWide ?? Int(bounds.width)) / bounds.width
        let scaleY = CGFloat(sourceImage.representations.first?.pixelsHigh ?? Int(bounds.height)) / bounds.height
        let pixelWidth = max(1, Int((selection.width * scaleX).rounded())), pixelHeight = max(1, Int((selection.height * scaleY).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapData = rep.bitmapData,
              let cgContext = CGContext(data: bitmapData, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: rep.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        rep.size = selection.size
        cgContext.translateBy(x: 0, y: CGFloat(pixelHeight))
        cgContext.scaleBy(x: scaleX, y: -scaleY)
        cgContext.translateBy(x: -selection.minX, y: -selection.minY)
        let context = NSGraphicsContext(cgContext: cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        drawScreenImage(sourceImage)
        if includeAnnotations { drawAnnotations() }
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: selection.size); result.addRepresentation(rep); return result
    }

    private func drawScreenImage(_ image: NSImage, interpolation: NSImageInterpolation = .high) {
        NSGraphicsContext.current?.imageInterpolation = interpolation
        image.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private static func makePixelatedImage(from image: CGImage, displaySize: CGSize) -> NSImage {
        let width = max(1, image.width / 16), height = max(1, image.height / 16)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage(cgImage: image, size: displaySize) }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return NSImage(cgImage: image, size: displaySize) }
        return NSImage(cgImage: small, size: displaySize)
    }
}
