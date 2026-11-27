// [INPUT]: CapturedScreenSnapshot、TranslationSceneSession、ScreenshotAnnotation 与 AppKit/CoreGraphics。
// [OUTPUT]: 全屏聚焦遮罩、窗口自动吸附、三分线辅助与矩形/箭头/画笔实时矢量标注画布。
// [POS]: 截图全屏蒙层的鼠标与绘制画布；由 ScreenshotOverlayController 创建并持有。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import CoreGraphics
import VorsmateCore
import VorsmateSystem

final class CaptureCanvasView: NSView {
    let snapshot: CapturedScreenSnapshot
    var sceneSession: TranslationSceneSession?
    var onHoverSnapChanged: (() -> Void)?
    var onSelectionDragStarted: (() -> Void)?
    var onSelectionCompleted: ((CapturedScreenSnapshot, CGRect) -> Void)?
    var onSelectionResized: ((CapturedScreenSnapshot, CGRect) -> Void)?
    var onSelectionInteractionEndedWithoutChange: ((CapturedScreenSnapshot, CGRect) -> Void)?
    var onAnnotationAdded: ((ScreenshotAnnotation) -> Void)?
    var onDoubleClickConfirm: (() -> Void)?
    var onCancelRequested: (() -> Void)?

    private enum DragInteraction: Equatable {
        case none
        case creating(start: NSPoint, snappedCandidate: CGRect?, movedBeyondThreshold: Bool)
        case resizing(handle: ScreenshotSelectionGeometry.Handle, initialRect: CGRect, start: NSPoint, moved: Bool)
        case annotating(
            tool: ScreenshotTool,
            color: AnnotationColor,
            size: AnnotationStrokeSize,
            startNorm: CGPoint,
            currentNorm: CGPoint,
            penPoints: [CGPoint])
    }

    private let localWindowRects: [CGRect]
    private var localSelectionRect: CGRect?
    private var hoveredSnappedRect: CGRect?
    private var dragInteraction: DragInteraction = .none
    private var trackingAreaRef: NSTrackingArea?

    private var isCreatingOrResizing: Bool {
        switch dragInteraction {
        case .creating(_, _, let moved): moved
        case .resizing: true
        case .none, .annotating: false
        }
    }

    private var shouldShowRuleOfThirds: Bool {
        switch dragInteraction {
        case .creating(_, _, let moved): moved
        case .resizing(let handle, _, _, _): handle != .inside
        case .none, .annotating: false
        }
    }

    init(snapshot: CapturedScreenSnapshot) {
        self.snapshot = snapshot
        self.localWindowRects = snapshot.windowRects.map {
            $0.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY)
        }
        super.init(frame: NSRect(origin: .zero, size: snapshot.screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    func applySceneSession(_ session: TranslationSceneSession?) {
        sceneSession = session
        guard dragInteraction == .none else {
            needsDisplay = true
            return
        }
        if let session {
            localSelectionRect = CGRect(
                x: session.selectionScreenRect.minX - snapshot.screenFrame.minX,
                y: session.selectionScreenRect.minY - snapshot.screenFrame.minY,
                width: session.selectionScreenRect.width,
                height: session.selectionScreenRect.height)
            hoveredSnappedRect = nil
        } else {
            localSelectionRect = nil
        }
        if let window {
            updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        needsDisplay = true
    }

    func clearSelection() {
        dragInteraction = .none
        localSelectionRect = nil
        hoveredSnappedRect = nil
        sceneSession = nil
        needsDisplay = true
    }

    func clearHoverSnap() {
        guard hoveredSnappedRect != nil else { return }
        hoveredSnappedRect = nil
        needsDisplay = true
    }

    func updateHoverSnap(at localPoint: NSPoint) {
        guard localSelectionRect == nil else { return }
        hoveredSnappedRect = ScreenshotSelectionGeometry.snappedWindowRect(
            at: localPoint,
            windows: localWindowRects,
            within: bounds)
        needsDisplay = true
    }

    func refreshCursorAndSnap(atScreenPoint screenPoint: NSPoint) {
        let localPoint = NSPoint(
            x: screenPoint.x - snapshot.screenFrame.minX,
            y: screenPoint.y - snapshot.screenFrame.minY)
        guard bounds.contains(localPoint) else { return }
        updateHoverSnap(at: localPoint)
        updateCursor(at: localPoint)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancelRequested?()
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursor(at: pt)

        guard localSelectionRect == nil else { return }
        let nextSnap = ScreenshotSelectionGeometry.snappedWindowRect(
            at: pt,
            windows: localWindowRects,
            within: bounds)
        if nextSnap != hoveredSnappedRect {
            hoveredSnappedRect = nextSnap
            onHoverSnapChanged?()
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = clampedPoint(convert(event.locationInWindow, from: nil))

        if let rect = localSelectionRect, let session = sceneSession {
            let activeTool = session.activeTool
            if activeTool != .none {
                guard rect.contains(pt) else { return }
                let norm = normalizedPoint(pt, in: rect)
                dragInteraction = .annotating(
                    tool: activeTool,
                    color: session.activeColor,
                    size: session.activeStrokeSize,
                    startNorm: norm,
                    currentNorm: norm,
                    penPoints: [norm])
                updateCursor(at: pt)
                needsDisplay = true
                return
            }

            if event.clickCount == 2 && rect.contains(pt) {
                onDoubleClickConfirm?()
                return
            }

            if let handle = ScreenshotSelectionGeometry.hitTest(point: pt, selection: rect, tolerance: 9) {
                dragInteraction = .resizing(handle: handle, initialRect: rect, start: pt, moved: false)
                updateCursor(at: pt)
                onSelectionDragStarted?()
                needsDisplay = true
                return
            }

            dragInteraction = .creating(start: pt, snappedCandidate: nil, movedBeyondThreshold: false)
            updateCursor(at: pt)
            onSelectionDragStarted?()
            needsDisplay = true
            return
        }

        let snap =
            hoveredSnappedRect
            ?? ScreenshotSelectionGeometry.snappedWindowRect(at: pt, windows: localWindowRects, within: bounds)
        dragInteraction = .creating(start: pt, snappedCandidate: snap, movedBeyondThreshold: false)
        updateCursor(at: pt)
        onSelectionDragStarted?()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = clampedPoint(convert(event.locationInWindow, from: nil))
        defer { updateCursor(at: pt) }

        switch dragInteraction {
        case .none:
            return

        case .creating(let start, let snapped, let moved):
            let dist = hypot(pt.x - start.x, pt.y - start.y)
            let nextMoved = moved || dist >= 4
            guard nextMoved else { return }
            dragInteraction = .creating(start: start, snappedCandidate: snapped, movedBeyondThreshold: true)
            hoveredSnappedRect = nil
            localSelectionRect = CGRect(
                x: min(start.x, pt.x),
                y: min(start.y, pt.y),
                width: abs(pt.x - start.x),
                height: abs(pt.y - start.y))
            needsDisplay = true

        case .resizing(let handle, let initialRect, let start, _):
            let delta = CGSize(width: pt.x - start.x, height: pt.y - start.y)
            let nextRect = ScreenshotSelectionGeometry.resize(
                selection: initialRect,
                handle: handle,
                delta: delta,
                within: bounds,
                minSize: 12)
            localSelectionRect = nextRect
            dragInteraction = .resizing(
                handle: handle,
                initialRect: initialRect,
                start: start,
                moved: nextRect != initialRect)
            needsDisplay = true

        case .annotating(let tool, let color, let size, let startNorm, _, var penPoints):
            guard let rect = localSelectionRect else { return }
            let clamped = clamp(pt, to: rect)
            let norm = normalizedPoint(clamped, in: rect)
            if tool == .pen {
                if let last = penPoints.last {
                    let dx = (norm.x - last.x) * rect.width
                    let dy = (norm.y - last.y) * rect.height
                    if hypot(dx, dy) >= 1.5 {
                        penPoints.append(norm)
                    }
                } else {
                    penPoints.append(norm)
                }
            }
            dragInteraction = .annotating(
                tool: tool,
                color: color,
                size: size,
                startNorm: startNorm,
                currentNorm: norm,
                penPoints: penPoints)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = clampedPoint(convert(event.locationInWindow, from: nil))
        let interaction = dragInteraction
        dragInteraction = .none
        defer { updateCursor(at: pt) }

        switch interaction {
        case .none:
            return

        case .creating(_, let snappedCandidate, let movedBeyondThreshold):
            if !movedBeyondThreshold {
                if let snapped = snappedCandidate {
                    localSelectionRect = snapped
                    hoveredSnappedRect = nil
                    needsDisplay = true
                    onSelectionCompleted?(snapshot, screenRect(from: snapped))
                    return
                }
                if let session = sceneSession {
                    let existing = CGRect(
                        x: session.selectionScreenRect.minX - snapshot.screenFrame.minX,
                        y: session.selectionScreenRect.minY - snapshot.screenFrame.minY,
                        width: session.selectionScreenRect.width,
                        height: session.selectionScreenRect.height)
                    localSelectionRect = existing
                    needsDisplay = true
                    onSelectionInteractionEndedWithoutChange?(snapshot, session.selectionScreenRect)
                    return
                }
                localSelectionRect = nil
                needsDisplay = true
                onCancelRequested?()
                return
            }

            guard let rect = localSelectionRect, rect.width >= 12, rect.height >= 12 else {
                localSelectionRect = nil
                needsDisplay = true
                onCancelRequested?()
                return
            }
            needsDisplay = true
            onSelectionCompleted?(snapshot, screenRect(from: rect))

        case .resizing(_, let initialRect, _, let moved):
            guard let rect = localSelectionRect else { return }
            let finalScreenRect = screenRect(from: rect)
            needsDisplay = true
            if moved && rect != initialRect {
                onSelectionResized?(snapshot, finalScreenRect)
            } else {
                onSelectionInteractionEndedWithoutChange?(snapshot, finalScreenRect)
            }

        case .annotating(let tool, let color, let size, let startNorm, let currentNorm, let penPoints):
            defer { needsDisplay = true }
            guard let rect = localSelectionRect else { return }
            switch tool {
            case .none:
                return
            case .rectangle:
                let normRect = CGRect(
                    x: min(startNorm.x, currentNorm.x),
                    y: min(startNorm.y, currentNorm.y),
                    width: abs(currentNorm.x - startNorm.x),
                    height: abs(currentNorm.y - startNorm.y))
                guard normRect.width * rect.width >= 3, normRect.height * rect.height >= 3 else { return }
                onAnnotationAdded?(
                    ScreenshotAnnotation(kind: .rectangle(rect: normRect), color: color, size: size))
            case .arrow:
                let dist = hypot(
                    (currentNorm.x - startNorm.x) * rect.width,
                    (currentNorm.y - startNorm.y) * rect.height)
                guard dist >= 4 else { return }
                onAnnotationAdded?(
                    ScreenshotAnnotation(kind: .arrow(start: startNorm, end: currentNorm), color: color, size: size))
            case .pen:
                let points = penPoints.isEmpty ? [startNorm, currentNorm] : penPoints
                onAnnotationAdded?(
                    ScreenshotAnnotation(kind: .pen(points: points), color: color, size: size))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.draw(snapshot.image, in: bounds)

        let displayRect = localSelectionRect ?? hoveredSnappedRect
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        if let rect = displayRect, rect.width >= 1, rect.height >= 1 {
            let outer = CGMutablePath()
            outer.addRect(bounds)
            outer.addRect(rect)
            ctx.addPath(outer)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        if let rect = displayRect, rect.width >= 1, rect.height >= 1 {
            if localSelectionRect != nil && !isCreatingOrResizing, let session = sceneSession {
                ctx.draw(session.compositeImage, in: rect)
            }

            if case .annotating(let tool, let color, let size, let startNorm, let currentNorm, let penPoints) =
                dragInteraction
            {
                drawLiveAnnotation(
                    in: ctx,
                    selectionRect: rect,
                    tool: tool,
                    color: color,
                    size: size,
                    startNorm: startNorm,
                    currentNorm: currentNorm,
                    penPoints: penPoints)
            }

            if shouldShowRuleOfThirds {
                drawRuleOfThirds(in: ctx, rect: rect)
            }

            drawSpotlightBorderAndHandles(
                in: ctx,
                rect: rect,
                showHandles: localSelectionRect != nil)

            drawSizePill(in: ctx, rect: rect)
        }
    }

    private func drawSpotlightBorderAndHandles(in ctx: CGContext, rect: CGRect, showHandles: Bool) {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(0.32).cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(showHandles ? 1.0 : 1.5)
        ctx.stroke(rect)
        ctx.restoreGState()

        guard showHandles else { return }

        // 4 flush on-line right-angle corner caps (12×12pt, 2.5pt stroke, zero gap).
        let capLen: CGFloat = min(12, min(rect.width, rect.height) * 0.45)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.square)
        ctx.setLineJoin(.miter)

        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (
                CGPoint(x: rect.minX, y: rect.minY + capLen), CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.minX + capLen, y: rect.minY)
            ),
            (
                CGPoint(x: rect.maxX - capLen, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY + capLen)
            ),
            (
                CGPoint(x: rect.maxX, y: rect.maxY - capLen), CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.maxX - capLen, y: rect.maxY)
            ),
            (
                CGPoint(x: rect.minX + capLen, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY - capLen)
            ),
        ]
        for (p1, corner, p2) in corners {
            ctx.move(to: p1)
            ctx.addLine(to: corner)
            ctx.addLine(to: p2)
            ctx.strokePath()
        }

        // 4 midpoint white-filled accent-stroked capsule pills (18×5pt horizontal / 5×18pt vertical).
        let pills: [CGRect] = [
            CGRect(x: rect.midX - 9, y: rect.maxY - 2.5, width: 18, height: 5),
            CGRect(x: rect.midX - 9, y: rect.minY - 2.5, width: 18, height: 5),
            CGRect(x: rect.minX - 2.5, y: rect.midY - 9, width: 5, height: 18),
            CGRect(x: rect.maxX - 2.5, y: rect.midY - 9, width: 5, height: 18),
        ]
        for pill in pills {
            let radius = min(pill.width, pill.height) / 2
            let path = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.25)
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawRuleOfThirds(in ctx: CGContext, rect: CGRect) {
        guard rect.width >= 36, rect.height >= 36 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        for step in [1.0 / 3.0, 2.0 / 3.0] {
            let x = rect.minX + rect.width * step
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * step
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawSizePill(in ctx: CGContext, rect: CGRect) {
        let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let pillWidth = ceil(textSize.width) + 14
        let pillHeight: CGFloat = 22

        let originX = max(8, min(rect.minX, bounds.maxX - pillWidth - 8))
        var originY = rect.maxY + 8
        if originY + pillHeight > bounds.maxY - 6 {
            originY = max(8, rect.maxY - pillHeight - 8)
        }
        let pillRect = CGRect(x: originX, y: originY, width: pillWidth, height: pillHeight)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 11, cornerHeight: 11, transform: nil)

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(pillPath)
        ctx.strokePath()
        ctx.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let textPoint = NSPoint(
            x: pillRect.minX + (pillRect.width - textSize.width) / 2,
            y: pillRect.minY + (pillRect.height - textSize.height) / 2)
        (label as NSString).draw(at: textPoint, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLiveAnnotation(
        in ctx: CGContext,
        selectionRect: CGRect,
        tool: ScreenshotTool,
        color: AnnotationColor,
        size: AnnotationStrokeSize,
        startNorm: CGPoint,
        currentNorm: CGPoint,
        penPoints: [CGPoint]
    ) {
        ctx.saveGState()
        ctx.clip(to: selectionRect)
        let cgColor = CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        let strokeWidth = size.lineWidth
        ctx.setStrokeColor(cgColor)
        ctx.setFillColor(cgColor)
        ctx.setLineWidth(strokeWidth)

        switch tool {
        case .none:
            break
        case .rectangle:
            let p1 = denormalizedPoint(startNorm, in: selectionRect)
            let p2 = denormalizedPoint(currentNorm, in: selectionRect)
            let drawRect = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y))
            if drawRect.width >= 1 || drawRect.height >= 1 {
                let radius = min(6, min(drawRect.width, drawRect.height) * 0.25)
                let path = CGPath(roundedRect: drawRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.setLineJoin(.round)
                ctx.addPath(path)
                ctx.strokePath()
            }
        case .arrow:
            let p1 = denormalizedPoint(startNorm, in: selectionRect)
            let p2 = denormalizedPoint(currentNorm, in: selectionRect)
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let length = hypot(dx, dy)
            if length >= 1 {
                let ux = dx / length
                let uy = dy / length
                let px = -uy
                let py = ux
                let headLength = min(length * 0.65, max(strokeWidth * 3.4, 14))
                let headHalfWidth = headLength * 0.42
                let shaftEnd = CGPoint(x: p2.x - ux * headLength * 0.72, y: p2.y - uy * headLength * 0.72)

                ctx.setLineCap(.round)
                ctx.move(to: p1)
                ctx.addLine(to: shaftEnd)
                ctx.strokePath()

                let baseCenter = CGPoint(x: p2.x - ux * headLength, y: p2.y - uy * headLength)
                let leftWing = CGPoint(x: baseCenter.x + px * headHalfWidth, y: baseCenter.y + py * headHalfWidth)
                let rightWing = CGPoint(x: baseCenter.x - px * headHalfWidth, y: baseCenter.y - py * headHalfWidth)
                ctx.move(to: p2)
                ctx.addLine(to: leftWing)
                ctx.addLine(to: rightWing)
                ctx.closePath()
                ctx.fillPath()
            }
        case .pen:
            guard let first = penPoints.first else { break }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let startPt = denormalizedPoint(first, in: selectionRect)
            ctx.move(to: startPt)
            if penPoints.count == 1 {
                ctx.addLine(to: startPt)
            } else {
                for pt in penPoints.dropFirst() {
                    ctx.addLine(to: denormalizedPoint(pt, in: selectionRect))
                }
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func updateCursor(at pt: NSPoint) {
        if subviews.contains(where: { !$0.isHidden && $0.frame.insetBy(dx: -2, dy: -2).contains(pt) }) {
            NSCursor.arrow.set()
            return
        }

        switch dragInteraction {
        case .creating(_, _, true), .annotating:
            NSCursor.crosshair.set()
            return
        case .resizing(let handle, _, _, _):
            (handle == .inside ? NSCursor.closedHand : cursor(for: handle)).set()
            return
        case .none, .creating(_, _, false):
            break
        }

        guard let rect = localSelectionRect else {
            NSCursor.crosshair.set()
            return
        }

        if (sceneSession?.activeTool ?? .none) != .none {
            (rect.contains(pt) ? NSCursor.crosshair : NSCursor.arrow).set()
            return
        }

        let handle = ScreenshotSelectionGeometry.hitTest(point: pt, selection: rect, tolerance: 9)
        cursor(for: handle).set()
    }

    private func cursor(for handle: ScreenshotSelectionGeometry.Handle?) -> NSCursor {
        switch handle {
        case .none:
            return .arrow
        case .inside:
            return .openHand
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft:
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: .topLeft, directions: .all)
            }
            return .crosshair
        case .topRight:
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: .topRight, directions: .all)
            }
            return .crosshair
        case .bottomLeft:
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: .bottomLeft, directions: .all)
            }
            return .crosshair
        case .bottomRight:
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: .bottomRight, directions: .all)
            }
            return .crosshair
        }
    }

    private func clampedPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: max(bounds.minX, min(point.x, bounds.maxX)),
            y: max(bounds.minY, min(point.y, bounds.maxY)))
    }

    private func clamp(_ point: NSPoint, to rect: CGRect) -> NSPoint {
        NSPoint(
            x: max(rect.minX, min(point.x, rect.maxX)),
            y: max(rect.minY, min(point.y, rect.maxY)))
    }

    private func normalizedPoint(_ point: NSPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.width > 0 ? max(0, min(1, (point.x - rect.minX) / rect.width)) : 0,
            y: rect.height > 0 ? max(0, min(1, (point.y - rect.minY) / rect.height)) : 0)
    }

    private func denormalizedPoint(_ norm: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + norm.x * rect.width,
            y: rect.minY + norm.y * rect.height)
    }

    private func screenRect(from localRect: CGRect) -> CGRect {
        CGRect(
            x: snapshot.screenFrame.minX + localRect.minX,
            y: snapshot.screenFrame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height)
    }
}
