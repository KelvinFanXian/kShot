import AppKit

final class CaptureWindow: NSWindow {
    var completion: ((CaptureResult) -> Void)? { didSet { captureView?.completion = completion } }
    var captureDidBegin: (() -> Void)? { didSet { captureView?.captureDidBegin = captureDidBegin } }

    private var captureView: CaptureView?

    init(screen: NSScreen, image: CGImage) {
        let captureView = CaptureView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image)
        self.captureView = captureView
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

    func releaseCaptureContent() {
        completion = nil
        captureDidBegin = nil
        contentView = nil
        captureView = nil
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum Interaction {
    case idle, selecting, drawing, recognizingText
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
    private var selection: CGRect = .zero
    private var interaction: Interaction = .idle
    private var dragStart: CGPoint = .zero
    private var currentPoint: CGPoint = .zero
    private var selectedTool: AnnotationTool?
    private var isOCRToolSelected = false
    private var ocrSelection: CGRect = .zero
    private var annotationHistory = AnnotationHistory()
    private var draftMosaic: [CGPoint] = []
    private var textEditor: NSTextField?
    private var hoveredButtonIndex: Int?
    private var hasAnnouncedCapture = false
    private var isFinishing = false
    private let buttonSize: CGFloat = 34
    private let buttonSpacing: CGFloat = 6
    private let toolbarPadding: CGFloat = 7

    init(frame: CGRect, image: CGImage) {
        sourceImage = NSImage(cgImage: image, size: frame.size)
        pixelatedImage = CaptureView.makePixelatedImage(from: image, displaySize: frame.size)
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selection.isEmpty ? .crosshair : .arrow)
        guard !selection.isEmpty else { return }
        let selectionCursor: NSCursor
        if isOCRToolSelected || selectedTool == .rectangle || selectedTool == .arrow || selectedTool == .mosaic {
            selectionCursor = .crosshair
        } else if selectedTool == .text {
            selectionCursor = .iBeam
        } else {
            selectionCursor = .openHand
        }
        addCursorRect(selection, cursor: selectionCursor)
        addCursorRect(toolbarRect, cursor: .pointingHand)
        for handle in ResizeHandle.allCases {
            let point = selection.point(for: handle)
            let rect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            switch handle {
            case .top, .bottom: addCursorRect(rect, cursor: .resizeUpDown)
            case .left, .right: addCursorRect(rect, cursor: .resizeLeftRight)
            case .topLeft, .bottomRight: addCursorRect(rect, cursor: diagonalNWSECursor)
            case .topRight, .bottomLeft: addCursorRect(rect, cursor: diagonalNESWCursor)
            }
        }
    }

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
        drawOCRSelection()
        NSGraphicsContext.restoreGraphicsState()
        drawSelectionChrome()
        drawDimensionLabel()
        if case .selecting = interaction { return }
        drawToolbar()
        if isOCRToolSelected { drawOCRHint() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if event.clickCount == 2, selection.contains(point), selectedTool != .text, !isOCRToolSelected { completeCapture(); return }
        if !selection.isEmpty, toolbarRect.contains(point) { handleToolbarClick(at: point); return }
        announceCaptureIfNeeded()
        dragStart = point
        currentPoint = point

        if !selection.isEmpty, let handle = resizeHandle(at: point) {
            interaction = .resizing(handle: handle, origin: selection)
        } else if !selection.isEmpty, selection.contains(point), isOCRToolSelected {
            ocrSelection = .zero
            interaction = .recognizingText
        } else if !selection.isEmpty, selection.contains(point), let selectedTool {
            switch selectedTool {
            case .text: beginTextEditing(at: point); interaction = .idle
            case .mosaic: draftMosaic = [clamped(point)]; interaction = .drawing
            case .rectangle, .arrow: interaction = .drawing
            }
        } else if !selection.isEmpty, selection.contains(point) {
            interaction = .moving(origin: selection)
            NSCursor.closedHand.set()
        } else {
            commitTextEditor()
            annotationHistory.removeAll()
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
        case .recognizingText:
            ocrSelection = CGRect(from: dragStart, to: clamped(point)).intersection(selection)
        case .idle: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        var recognizedRect: CGRect?
        switch interaction {
        case .selecting, .moving, .resizing:
            selection = selection.standardized.integral
            if selection.width < 3 || selection.height < 3 { selection = .zero }
        case .drawing: commitDraftAnnotation()
        case .recognizingText:
            ocrSelection = ocrSelection.standardized.integral.intersection(selection)
            if ocrSelection.width >= 3, ocrSelection.height >= 3 { recognizedRect = ocrSelection }
        case .idle: break
        }
        interaction = .idle
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        if let recognizedRect { recognizeText(in: recognizedRect) }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newIndex = toolbarRect.contains(point) ? buttonIndex(at: point) : nil
        guard newIndex != hoveredButtonIndex else { return }
        hoveredButtonIndex = newIndex
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            event.modifierFlags.contains(.shift) ? redoAnnotation() : undoAnnotation()
            return
        }
        switch event.keyCode {
        case 53: finish(.cancelled)
        case 36, 76: completeCapture()
        case 51, 117: undoAnnotation()
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
            isOCRToolSelected = false
            ocrSelection = .zero
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        if ocrButtonRect.contains(point) {
            isOCRToolSelected.toggle()
            selectedTool = nil
            ocrSelection = .zero
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
        else if undoButtonRect.contains(point) { undoAnnotation() }
        else if redoButtonRect.contains(point) { redoAnnotation() }
        else if cancelButtonRect.contains(point) { finish(.cancelled) }
        else if doneButtonRect.contains(point) { completeCapture() }
    }

    private func undoAnnotation() {
        commitTextEditor()
        if annotationHistory.undo() { needsDisplay = true }
    }

    private func redoAnnotation() {
        commitTextEditor()
        if annotationHistory.redo() { needsDisplay = true }
    }

    private func completeCapture() {
        commitTextEditor()
        guard selection.width >= 3, selection.height >= 3, let image = renderSelection(includeAnnotations: true) else { return }
        finish(.completed(image))
    }

    private func recognizeText(in rect: CGRect) {
        commitTextEditor()
        guard rect.width >= 3, rect.height >= 3,
              let image = render(rect: rect, includeAnnotations: false) else { return }
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
            if rect.width > 2, rect.height > 2 { annotationHistory.append(.rectangle(rect)) }
        case .arrow:
            if hypot(end.x - dragStart.x, end.y - dragStart.y) > 3 { annotationHistory.append(.arrow(from: dragStart, to: end)) }
        case .mosaic:
            if draftMosaic.count > 1 { annotationHistory.append(.mosaic(draftMosaic)) }
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
        if !text.isEmpty { annotationHistory.append(.text(text, at: editor.frame.origin)) }
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
        let text = "拖动鼠标选择区域  ·  Esc 取消"
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
        for tool in AnnotationTool.allCases {
            let index = AnnotationTool.allCases.firstIndex(of: tool) ?? 0
            drawButton(rect: toolButtonRect(tool), symbol: tool.symbolName, selected: tool == selectedTool, hovered: hoveredButtonIndex == index)
        }
        drawButton(rect: ocrButtonRect, symbol: "text.viewfinder", selected: isOCRToolSelected, hovered: hoveredButtonIndex == ocrButtonIndex, color: .systemBlue)
        drawButton(rect: undoButtonRect, symbol: "arrow.uturn.backward", hovered: hoveredButtonIndex == undoButtonIndex, enabled: annotationHistory.canUndo)
        drawButton(rect: redoButtonRect, symbol: "arrow.uturn.forward", hovered: hoveredButtonIndex == redoButtonIndex, enabled: annotationHistory.canRedo)
        drawButton(rect: cancelButtonRect, symbol: "xmark", hovered: hoveredButtonIndex == cancelButtonIndex, color: .secondaryLabelColor)
        drawButton(rect: doneButtonRect, symbol: "checkmark", hovered: hoveredButtonIndex == doneButtonIndex, color: .systemGreen)
    }

    private func drawButton(rect: CGRect, symbol: String, selected: Bool = false, hovered: Bool = false, enabled: Bool = true, color: NSColor = .labelColor) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        } else if hovered, enabled {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let configured = image.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? image
        (enabled ? color : NSColor.tertiaryLabelColor).set()
        configured.draw(
            in: CGRect(x: rect.midX - 9, y: rect.midY - 9, width: 18, height: 18),
            from: .zero,
            operation: .sourceOver,
            fraction: enabled ? 1 : 0.55,
            respectFlipped: true,
            hints: nil
        )
    }

    private var toolbarRect: CGRect {
        let count = CGFloat(AnnotationTool.allCases.count + 5)
        let width = toolbarPadding * 2 + count * buttonSize + (count - 1) * buttonSpacing
        var x = min(max(8, selection.maxX - width), bounds.width - width - 8)
        if bounds.width < width + 16 { x = 0 }
        var y = selection.maxY + 8
        if y + buttonSize + toolbarPadding * 2 > bounds.height { y = selection.maxY - buttonSize - toolbarPadding * 2 - 8 }
        return CGRect(x: x, y: y, width: width, height: buttonSize + toolbarPadding * 2)
    }

    private func toolButtonRect(_ tool: AnnotationTool) -> CGRect { buttonRect(index: AnnotationTool.allCases.firstIndex(of: tool) ?? 0) }
    private var ocrButtonIndex: Int { AnnotationTool.allCases.count }
    private var undoButtonIndex: Int { ocrButtonIndex + 1 }
    private var redoButtonIndex: Int { ocrButtonIndex + 2 }
    private var cancelButtonIndex: Int { ocrButtonIndex + 3 }
    private var doneButtonIndex: Int { ocrButtonIndex + 4 }
    private var ocrButtonRect: CGRect { buttonRect(index: ocrButtonIndex) }
    private var undoButtonRect: CGRect { buttonRect(index: undoButtonIndex) }
    private var redoButtonRect: CGRect { buttonRect(index: redoButtonIndex) }
    private var cancelButtonRect: CGRect { buttonRect(index: cancelButtonIndex) }
    private var doneButtonRect: CGRect { buttonRect(index: doneButtonIndex) }
    private func buttonRect(index: Int) -> CGRect {
        CGRect(x: toolbarRect.minX + toolbarPadding + CGFloat(index) * (buttonSize + buttonSpacing), y: toolbarRect.minY + toolbarPadding, width: buttonSize, height: buttonSize)
    }

    private func buttonIndex(at point: CGPoint) -> Int? {
        let count = AnnotationTool.allCases.count + 5
        return (0..<count).first { buttonRect(index: $0).contains(point) }
    }

    private var diagonalNWSECursor: NSCursor {
        makeCursor(symbol: "arrow.up.left.and.arrow.down.right")
    }

    private var diagonalNESWCursor: NSCursor {
        makeCursor(symbol: "arrow.up.right.and.arrow.down.left")
    }

    private func makeCursor(symbol name: String) -> NSCursor {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return .crosshair }
        let canvas = NSImage(size: NSSize(width: 22, height: 22))
        canvas.lockFocus()
        symbol.draw(in: NSRect(x: 2, y: 2, width: 18, height: 18))
        canvas.unlockFocus()
        return NSCursor(image: canvas, hotSpot: NSPoint(x: 11, y: 11))
    }

    private func drawAnnotations() { annotationHistory.items.forEach(drawAnnotation) }

    private func drawDraft() {
        guard case .drawing = interaction else { return }
        switch selectedTool {
        case .rectangle: drawAnnotation(.rectangle(CGRect(from: dragStart, to: clamped(currentPoint))))
        case .arrow: drawAnnotation(.arrow(from: dragStart, to: clamped(currentPoint)))
        case .mosaic: drawAnnotation(.mosaic(draftMosaic))
        case .text, .none: break
        }
    }

    private func drawOCRSelection() {
        guard !ocrSelection.isEmpty else { return }
        NSColor.systemBlue.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: ocrSelection, xRadius: 3, yRadius: 3).fill()
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(roundedRect: ocrSelection.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 2
        border.stroke()
    }

    private func drawOCRHint() {
        let text = "在截图内拖过文字，松手复制"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let width = size.width + 16
        let x = min(max(8, selection.minX), bounds.width - width - 8)
        let toolbarAboveSelection = toolbarRect.maxY <= selection.maxY
        let preferredY = toolbarAboveSelection ? toolbarRect.minY - 28 : toolbarRect.maxY + 6
        let y = min(max(8, preferredY), bounds.height - 28)
        let rect = CGRect(x: x, y: y, width: width, height: 24)
        NSColor.systemBlue.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 5), withAttributes: attrs)
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
        render(rect: selection, includeAnnotations: includeAnnotations)
    }

    private func render(rect: CGRect, includeAnnotations: Bool) -> NSImage? {
        let scaleX = CGFloat(sourceImage.representations.first?.pixelsWide ?? Int(bounds.width)) / bounds.width
        let scaleY = CGFloat(sourceImage.representations.first?.pixelsHigh ?? Int(bounds.height)) / bounds.height
        let pixelWidth = max(1, Int((rect.width * scaleX).rounded())), pixelHeight = max(1, Int((rect.height * scaleY).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapData = rep.bitmapData,
              let cgContext = CGContext(data: bitmapData, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: rep.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        rep.size = rect.size
        cgContext.translateBy(x: 0, y: CGFloat(pixelHeight))
        cgContext.scaleBy(x: scaleX, y: -scaleY)
        cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        let context = NSGraphicsContext(cgContext: cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        drawScreenImage(sourceImage)
        if includeAnnotations { drawAnnotations() }
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: rect.size); result.addRepresentation(rep); return result
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
