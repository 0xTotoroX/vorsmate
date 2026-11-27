// [INPUT]: CapturedScreenSnapshot、TranslationSceneSession、TranslationModel、ScreenshotAnnotation 与 AppKit/SwiftUI。
// [OUTPUT]: 全屏聚焦框选叠层（窗口吸附、矢量标注）、morphing Liquid Glass A2 工具栏与纯图标桌面贴图窗口。
// [POS]: 截图插件的核心视觉呈现层；框选后支持矩形/箭头/画笔标注、按需 OCR/翻译、复制/保存与可缩放透明贴图。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import CoreGraphics
import SwiftUI
import VorsmateCore
import VorsmateSystem

@MainActor
protocol ScreenshotOverlayPresenting: AnyObject {
    var isActive: Bool { get }
    var windowNumbers: [Int] { get }
    func beginCapture(snapshots: [CapturedScreenSnapshot])
    func setCaptureOverlayVisible(_ visible: Bool)
    func updateSceneState(_ session: TranslationSceneSession?)
    func pinCurrentScene(_ session: TranslationSceneSession)
    func closeCaptureOverlayOnly()
    func closeAll()
}

private final class OverlayKeyWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onSpaceToggle: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onUndo: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onNudge: ((CGFloat, CGFloat) -> Void)?
    var hasSelection: (() -> Bool)?
    var canNudge: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if handleShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleShortcut(event) {
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if event.keyCode == 49 && !event.isARepeat && (hasSelection?() ?? false) {
            onSpaceToggle?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76) && (hasSelection?() ?? false) {
            onConfirm?()
            return
        }
        if handleArrowNudge(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, hasSelection?() ?? false else { return false }
        switch event.keyCode {
        case 8:
            onCopy?()
            return true
        case 1:
            onSave?()
            return true
        case 6:
            onUndo?()
            return true
        default:
            return false
        }
    }

    private func handleArrowNudge(_ event: NSEvent) -> Bool {
        guard canNudge?() ?? false else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123:
            onNudge?(-step, 0)
            return true
        case 124:
            onNudge?(step, 0)
            return true
        case 125:
            onNudge?(0, -step)
            return true
        case 126:
            onNudge?(0, step)
            return true
        default:
            return false
        }
    }
}

@MainActor
private final class StickerHUDState: ObservableObject {
    enum HUDKind {
        case zoom
        case opacity
    }

    @Published var hudKind: HUDKind?
    @Published var hudPercent: Int = 100
    @Published var toastText: String?

    private var hideTask: Task<Void, Never>?

    func showZoom(_ zoom: CGFloat) {
        presentHUD(kind: .zoom, percent: Int((zoom * 100).rounded()))
    }

    func showOpacity(_ opacity: CGFloat) {
        presentHUD(kind: .opacity, percent: Int((opacity * 100).rounded()))
    }

    func showToast(_ message: String) {
        hideTask?.cancel()
        hudKind = nil
        toastText = message
        scheduleHide()
    }

    func cancelAll() {
        hideTask?.cancel()
        hideTask = nil
        hudKind = nil
        toastText = nil
    }

    private func presentHUD(kind: HUDKind, percent: Int) {
        hideTask?.cancel()
        toastText = nil
        hudKind = kind
        hudPercent = percent
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self?.hudKind = nil
                self?.toastText = nil
            }
        }
    }
}

private final class PinnedStickerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func scrollWheel(with event: NSEvent) { window?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { window?.magnify(with: event) }
}

private struct StickerOverlayBarAnchor: NSViewRepresentable {
    let onResolve: @MainActor (NSView?) -> Void

    final class AnchorView: NSView {
        var onResolve: (@MainActor (NSView?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window != nil ? self : nil)
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView(frame: .zero)
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.onResolve = onResolve
        if nsView.window != nil {
            onResolve(nsView)
        }
    }
}

private final class PinnedStickerWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onCleanup: (() -> Void)?
    weak var overlayBarView: NSView?

    private var baseSize: CGSize = .zero
    private var rawZoomScale: CGFloat = 1.0
    private var zoomScale: CGFloat = 1.0
    private var opacityValue: CGFloat = 1.0
    private var isApplyingProgrammaticZoom = false

    override var canBecomeKey: Bool { true }

    func configureStickerBaseSize(_ size: CGSize) {
        baseSize = size
        rawZoomScale = 1.0
        zoomScale = 1.0
        opacityValue = 1.0
    }

    func resetZoomTo100() {
        rawZoomScale = 1.0
        applyZoom(1.0)
        onZoomChanged?(1.0)
    }

    func syncZoomFromUserResize() {
        guard !isApplyingProgrammaticZoom, baseSize.width > 0 else { return }
        let measured = max(0.25, min(4.0, frame.width / baseSize.width))
        rawZoomScale = measured
        zoomScale = measured
        onZoomChanged?(measured)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        {
            onEscape?()
            return
        }
        if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) {
            let point = event.locationInWindow
            if isInOverlayBar(point) || isNearWindowEdge(point) {
                super.sendEvent(event)
                return
            }
            if event.clickCount == 2 {
                onEscape?()
                return
            }
            makeKey()
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if handleKey(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaSource =
            abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX
        let rawStep = event.hasPreciseScrollingDeltas ? deltaSource * 0.004 : deltaSource * 0.08
        let step = max(-0.35, min(0.35, rawStep))
        guard abs(step) > 0.0001 else { return }

        if event.modifierFlags.contains(.option) {
            opacityValue = max(0.25, min(1.0, opacityValue + step))
            alphaValue = opacityValue
            onOpacityChanged?(opacityValue)
        } else {
            rawZoomScale = max(0.25, min(4.0, rawZoomScale * (1.0 + step)))
            let displayZoom = abs(rawZoomScale - 1.0) < 0.015 ? 1.0 : rawZoomScale
            applyZoom(displayZoom)
            onZoomChanged?(displayZoom)
        }
    }

    override func magnify(with event: NSEvent) {
        let clamped = max(-0.35, min(0.35, event.magnification))
        guard abs(clamped) > 0.0001 else { return }
        rawZoomScale = max(0.25, min(4.0, rawZoomScale * (1.0 + clamped)))
        let displayZoom = abs(rawZoomScale - 1.0) < 0.015 ? 1.0 : rawZoomScale
        applyZoom(displayZoom)
        onZoomChanged?(displayZoom)
    }

    private func isInOverlayBar(_ point: CGPoint) -> Bool {
        guard let overlayBarView,
            overlayBarView.window === self,
            !overlayBarView.isHiddenOrHasHiddenAncestor
        else { return false }
        let rectInWindow = overlayBarView.convert(overlayBarView.bounds, to: nil)
        return rectInWindow.contains(point)
    }

    private func isNearWindowEdge(_ point: CGPoint) -> Bool {
        guard let contentBounds = contentView?.bounds,
            contentBounds.width > 0,
            contentBounds.height > 0
        else { return false }
        let edgeThreshold = min(7, min(contentBounds.width, contentBounds.height) * 0.2)
        return point.x <= contentBounds.minX + edgeThreshold
            || point.x >= contentBounds.maxX - edgeThreshold
            || point.y <= contentBounds.minY + edgeThreshold
            || point.y >= contentBounds.maxY - edgeThreshold
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {
            onEscape?()
            return true
        }
        if flags == .command || flags == [.command, .shift] {
            if event.keyCode == 24 || event.keyCode == 69 {
                let next = min(4.0, zoomScale * 1.15)
                rawZoomScale = next
                applyZoom(next)
                onZoomChanged?(next)
                return true
            }
        }
        if flags == .command {
            switch event.keyCode {
            case 8:
                onCopy?()
                return true
            case 1:
                onSave?()
                return true
            case 27, 78:
                let next = max(0.25, zoomScale / 1.15)
                rawZoomScale = next
                applyZoom(next)
                onZoomChanged?(next)
                return true
            case 29, 82:
                resetZoomTo100()
                return true
            default:
                break
            }
        }
        if flags.isEmpty && (event.keyCode == 29 || event.keyCode == 82) {
            resetZoomTo100()
            return true
        }
        return false
    }

    private func applyZoom(_ newZoom: CGFloat) {
        guard baseSize.width > 0, baseSize.height > 0 else { return }
        zoomScale = newZoom
        let newWidth = max(24, (baseSize.width * newZoom).rounded())
        let newHeight = max(24, (baseSize.height * newZoom).rounded())
        let current = frame
        let nextFrame = NSRect(
            x: (current.midX - newWidth / 2).rounded(),
            y: (current.midY - newHeight / 2).rounded(),
            width: newWidth,
            height: newHeight)
        isApplyingProgrammaticZoom = true
        defer { isApplyingProgrammaticZoom = false }
        setFrame(nextFrame, display: true)
    }
}

@MainActor
final class ScreenshotOverlayController: NSObject, ScreenshotOverlayPresenting, NSWindowDelegate {
    private weak var model: TranslationModel?
    private var captureWindows:
        [(snapshot: CapturedScreenSnapshot, window: OverlayKeyWindow, canvas: CaptureCanvasView)] = []
    private var captureOverlayHidden = false
    private var toolbarHost: NSHostingView<SceneOverlayToolbarView>?
    private var pinnedWindows: [PinnedStickerWindow] = []

    var isActive: Bool { !captureWindows.isEmpty && !captureOverlayHidden }
    var windowNumbers: [Int] {
        captureWindows.map { $0.window.windowNumber } + pinnedWindows.map { $0.windowNumber }
    }

    init(model: TranslationModel) {
        self.model = model
        super.init()
    }

    func beginCapture(snapshots: [CapturedScreenSnapshot]) {
        closeCaptureWindows()
        guard let model else { return }

        var created: [(snapshot: CapturedScreenSnapshot, window: OverlayKeyWindow, canvas: CaptureCanvasView)] = []
        let pointer = NSEvent.mouseLocation
        var targetKeyWindow: OverlayKeyWindow?

        for snapshot in snapshots {
            let canvas = CaptureCanvasView(snapshot: snapshot)
            canvas.onHoverSnapChanged = { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                for entry in self.captureWindows where entry.canvas !== canvas {
                    entry.canvas.clearHoverSnap()
                }
            }
            canvas.onSelectionDragStarted = { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                self.toolbarHost?.isHidden = true
                self.model?.beginSelectionInteraction()
                for entry in self.captureWindows where entry.canvas !== canvas {
                    entry.canvas.clearSelection()
                }
            }
            canvas.onSelectionCompleted = { [weak self] snap, screenRect in
                self?.positionToolbar(on: snap, selectionScreenRect: screenRect)
                self?.model?.completeScreenSelection(snapshot: snap, selectionScreenRect: screenRect)
            }
            canvas.onSelectionResized = { [weak self] snap, screenRect in
                self?.positionToolbar(on: snap, selectionScreenRect: screenRect)
                self?.model?.updateSelectionRect(snapshot: snap, selectionScreenRect: screenRect)
            }
            canvas.onSelectionInteractionEndedWithoutChange = { [weak self] snap, screenRect in
                self?.positionToolbar(on: snap, selectionScreenRect: screenRect)
            }
            canvas.onAnnotationAdded = { [weak self] annotation in
                self?.model?.addAnnotation(annotation)
            }
            canvas.onDoubleClickConfirm = { [weak self] in
                self?.model?.finishAndCopyImage()
            }
            canvas.onCancelRequested = { [weak self] in
                self?.model?.handleEscapeKey()
            }

            if snapshot.screenFrame.contains(pointer) {
                let localPointer = NSPoint(
                    x: pointer.x - snapshot.screenFrame.minX,
                    y: pointer.y - snapshot.screenFrame.minY)
                canvas.updateHoverSnap(at: localPointer)
            }

            let win = OverlayKeyWindow(
                contentRect: snapshot.screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            win.level = .screenSaver
            win.isOpaque = true
            win.hasShadow = false
            win.backgroundColor = .black
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.acceptsMouseMovedEvents = true
            win.isReleasedWhenClosed = false
            win.contentView = canvas
            win.hasSelection = { [weak self] in
                self?.model?.sceneSession != nil
            }
            win.canNudge = { [weak self] in
                guard let session = self?.model?.sceneSession else { return false }
                return session.activeTool == .none
            }
            win.onEscape = { [weak self] in
                self?.model?.handleEscapeKey()
            }
            win.onSpaceToggle = { [weak self] in
                self?.model?.toggleSceneComparison()
            }
            win.onCopy = { [weak self] in
                self?.model?.finishAndCopyImage()
            }
            win.onSave = { [weak self] in
                self?.model?.saveSceneImage()
            }
            win.onUndo = { [weak self] in
                self?.model?.undoAnnotation()
            }
            win.onConfirm = { [weak self] in
                self?.model?.finishAndCopyImage()
            }
            win.onNudge = { [weak self] dx, dy in
                self?.nudgeActiveSelection(dx: dx, dy: dy)
            }
            win.orderFrontRegardless()
            if snapshot.screenFrame.contains(pointer) {
                targetKeyWindow = win
            }
            created.append((snapshot: snapshot, window: win, canvas: canvas))
        }

        captureWindows = created
        let host = NSHostingView(rootView: SceneOverlayToolbarView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        host.isHidden = true
        host.translatesAutoresizingMaskIntoConstraints = true
        toolbarHost = host
        if let preferred = created.first(where: { $0.window === targetKeyWindow }) ?? created.first {
            preferred.canvas.addSubview(host)
        }

        Self.activateApplication()
        let targetEntry = created.first(where: { $0.window === targetKeyWindow }) ?? created.first
        if let targetEntry {
            targetEntry.window.makeKeyAndOrderFront(nil)
            targetEntry.window.makeFirstResponder(targetEntry.canvas)
            targetEntry.canvas.refreshCursorAndSnap(atScreenPoint: pointer)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                    let liveEntry = self.captureWindows.first(where: { $0.window === targetEntry.window })
                else { return }
                liveEntry.window.makeKeyAndOrderFront(nil)
                liveEntry.window.makeFirstResponder(liveEntry.canvas)
                liveEntry.canvas.refreshCursorAndSnap(atScreenPoint: NSEvent.mouseLocation)
            }
        }
    }

    func setCaptureOverlayVisible(_ visible: Bool) {
        let shouldHide = !visible
        guard captureOverlayHidden != shouldHide else { return }
        captureOverlayHidden = shouldHide
        if shouldHide {
            for entry in captureWindows {
                entry.window.orderOut(nil)
            }
            NSCursor.arrow.set()
            return
        }
        guard !captureWindows.isEmpty else { return }
        Self.activateApplication()
        for entry in captureWindows {
            entry.window.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let targetEntry =
            captureWindows.first(where: { $0.snapshot.screenFrame.contains(pointer) })
            ?? captureWindows.first
        if let targetEntry {
            targetEntry.window.makeKeyAndOrderFront(nil)
            targetEntry.window.makeFirstResponder(targetEntry.canvas)
            targetEntry.canvas.refreshCursorAndSnap(atScreenPoint: pointer)
        }
    }

    func updateSceneState(_ session: TranslationSceneSession?) {
        guard let session else {
            toolbarHost?.isHidden = true
            return
        }
        for entry in captureWindows {
            if entry.snapshot.screenFrame == session.screenFrame {
                entry.canvas.applySceneSession(session)
                positionToolbar(on: entry.snapshot, selectionScreenRect: session.selectionScreenRect)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                        let active = self.model?.sceneSession,
                        let activeEntry = self.captureWindows.first(where: {
                            $0.snapshot.screenFrame == active.screenFrame
                        })
                    else { return }
                    self.positionToolbar(
                        on: activeEntry.snapshot, selectionScreenRect: active.selectionScreenRect)
                }
            } else {
                entry.canvas.applySceneSession(nil)
            }
            entry.canvas.needsDisplay = true
        }
    }

    func pinCurrentScene(_ session: TranslationSceneSession) {
        closeCaptureWindows()
        guard let model else { return }

        let baseSize = session.selectionScreenRect.size
        let panel = PinnedStickerWindow(
            contentRect: session.selectionScreenRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        if baseSize.width > 0 && baseSize.height > 0 {
            panel.contentAspectRatio = baseSize
            panel.minSize = NSSize(
                width: max(24, (baseSize.width * 0.25).rounded()),
                height: max(24, (baseSize.height * 0.25).rounded()))
            panel.maxSize = NSSize(
                width: max(24, (baseSize.width * 4.0).rounded()),
                height: max(24, (baseSize.height * 4.0).rounded()))
        }
        panel.configureStickerBaseSize(baseSize)

        let hudState = StickerHUDState()
        let contentModel = PinnedStickerViewModel(session: session, model: model, hudState: hudState)
        panel.onEscape = { [weak self, weak panel] in
            guard let panel else { return }
            self?.removePinnedWindow(panel)
        }
        panel.onCopy = { [weak contentModel] in
            contentModel?.copyCurrentImage()
        }
        panel.onSave = { [weak contentModel] in
            contentModel?.saveCurrentImage()
        }
        panel.onZoomChanged = { [weak hudState] zoom in
            hudState?.showZoom(zoom)
        }
        panel.onOpacityChanged = { [weak hudState] opacity in
            hudState?.showOpacity(opacity)
        }
        panel.onCleanup = { [weak contentModel] in
            contentModel?.cancelAllTasks()
        }

        let boxView = PinnedStickerHostingView(
            rootView: PinnedStickerContent(
                viewModel: contentModel,
                hudState: hudState,
                onClose: { [weak self, weak panel] in
                    guard let panel else { return }
                    self?.removePinnedWindow(panel)
                },
                onOverlayBarResolve: { [weak panel] barView in
                    panel?.overlayBarView = barView
                }))
        panel.contentView = boxView
        pinnedWindows.append(panel)
        Self.activateApplication()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResize(_ notification: Notification) {
        (notification.object as? PinnedStickerWindow)?.syncZoomFromUserResize()
    }

    func closeCaptureOverlayOnly() {
        closeCaptureWindows()
    }

    func closeAll() {
        closeCaptureWindows()
        let stickers = pinnedWindows
        pinnedWindows.removeAll()
        for sticker in stickers {
            sticker.onCleanup?()
            sticker.onCleanup = nil
            sticker.delegate = nil
            sticker.contentView = nil
            sticker.close()
        }
    }

    private func nudgeActiveSelection(dx: CGFloat, dy: CGFloat) {
        guard let session = model?.sceneSession,
            session.activeTool == .none,
            let entry = captureWindows.first(where: { $0.snapshot.screenFrame == session.screenFrame })
        else { return }

        let local = CGRect(
            x: session.selectionScreenRect.minX - entry.snapshot.screenFrame.minX,
            y: session.selectionScreenRect.minY - entry.snapshot.screenFrame.minY,
            width: session.selectionScreenRect.width,
            height: session.selectionScreenRect.height)
        let nudged = ScreenshotSelectionGeometry.nudge(
            selection: local,
            dx: dx,
            dy: dy,
            within: entry.canvas.bounds)
        guard nudged != local else { return }

        let screenRect = CGRect(
            x: entry.snapshot.screenFrame.minX + nudged.minX,
            y: entry.snapshot.screenFrame.minY + nudged.minY,
            width: nudged.width,
            height: nudged.height)
        model?.updateSelectionRect(snapshot: entry.snapshot, selectionScreenRect: screenRect)
    }

    private func closeCaptureWindows() {
        captureOverlayHidden = false
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
        let windows = captureWindows
        captureWindows.removeAll()
        for entry in windows {
            entry.window.contentView = nil
            entry.window.close()
        }
        NSCursor.arrow.set()
    }

    private func removePinnedWindow(_ window: PinnedStickerWindow) {
        pinnedWindows.removeAll { $0 === window }
        window.onCleanup?()
        window.onCleanup = nil
        window.delegate = nil
        window.contentView = nil
        window.close()
    }

    private func positionToolbar(on snapshot: CapturedScreenSnapshot, selectionScreenRect: CGRect) {
        guard let host = toolbarHost,
            let targetEntry = captureWindows.first(where: { $0.snapshot.screenFrame == snapshot.screenFrame })
        else { return }

        if host.superview !== targetEntry.canvas {
            host.removeFromSuperview()
            targetEntry.canvas.addSubview(host)
        }
        host.isHidden = false
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let barWidth = max(240, ceil(size.width))
        let barHeight = max(36, ceil(size.height))

        let localSelection = CGRect(
            x: selectionScreenRect.minX - snapshot.screenFrame.minX,
            y: selectionScreenRect.minY - snapshot.screenFrame.minY,
            width: selectionScreenRect.width,
            height: selectionScreenRect.height)

        let canvasBounds = targetEntry.canvas.bounds
        var originX = localSelection.midX - barWidth / 2
        originX = max(12, min(originX, canvasBounds.width - barWidth - 12))

        // Anchor TOP edge (maxY) at localSelection.minY - 10 so Row 1 stays steady while Row 2 grows downward.
        let anchoredBelowY = localSelection.minY - 10 - barHeight
        let originY: CGFloat
        if anchoredBelowY >= 12 {
            originY = anchoredBelowY
        } else {
            let aboveY = localSelection.maxY + 10
            if aboveY + barHeight + 12 <= canvasBounds.height {
                originY = aboveY
            } else {
                originY = max(12, min(canvasBounds.height - barHeight - 12, anchoredBelowY))
            }
        }

        host.frame = NSRect(x: originX, y: originY, width: barWidth, height: barHeight)
    }

    private static func activateApplication() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class CaptureCanvasView: NSView {
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

private enum ScreenshotVectorIconKind {
    case rect
    case arrow
    case pen
    case undo
    case ocr
    case translate
    case pin
    case save
    case close
    case done
    case copy
    case zoomMini
    case opacityMini
}

private struct ScreenshotVectorIcon: View {
    let kind: ScreenshotVectorIconKind
    var size: CGFloat = 20

    var body: some View {
        let scale = size / 20.0
        let strokeWidth: CGFloat = (kind == .done ? 1.85 : 1.65) * scale
        let style = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)

        ZStack {
            strokePath(scale: scale)
                .stroke(style: style)
            if let fill = fillPath(scale: scale) {
                fill.fill()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func strokePath(scale: CGFloat) -> Path {
        var path = Path()
        switch kind {
        case .rect:
            path.addRoundedRect(
                in: CGRect(x: 3.5, y: 4.5, width: 13, height: 11), cornerSize: CGSize(width: 2, height: 2))
        case .arrow:
            path.move(to: CGPoint(x: 4.5, y: 15.5))
            path.addLine(to: CGPoint(x: 15, y: 5))
            path.move(to: CGPoint(x: 8.5, y: 4.5))
            path.addLine(to: CGPoint(x: 15.5, y: 4.5))
            path.addLine(to: CGPoint(x: 15.5, y: 11.5))
        case .pen:
            path.move(to: CGPoint(x: 6.3, y: 16.5))
            path.addLine(to: CGPoint(x: 7.7, y: 9.7))
            path.addLine(to: CGPoint(x: 10, y: 3.5))
            path.addLine(to: CGPoint(x: 12.3, y: 9.7))
            path.addLine(to: CGPoint(x: 13.7, y: 16.5))
            path.move(to: CGPoint(x: 7.7, y: 9.7))
            path.addLine(to: CGPoint(x: 12.3, y: 9.7))
        case .undo:
            path.move(to: CGPoint(x: 7.4, y: 4.5))
            path.addLine(to: CGPoint(x: 4.2, y: 7.5))
            path.addLine(to: CGPoint(x: 7.4, y: 10.5))
            path.move(to: CGPoint(x: 4.6, y: 7.5))
            path.addLine(to: CGPoint(x: 11.6, y: 7.5))
            path.addArc(
                center: CGPoint(x: 11.6, y: 11.25),
                radius: 3.75,
                startAngle: .degrees(-90),
                endAngle: .degrees(90),
                clockwise: false)
            path.addLine(to: CGPoint(x: 6.5, y: 15))
        case .ocr:
            path.move(to: CGPoint(x: 3.5, y: 7.0))
            path.addLine(to: CGPoint(x: 3.5, y: 4.0))
            path.addLine(to: CGPoint(x: 6.5, y: 4.0))
            path.move(to: CGPoint(x: 13.5, y: 4.0))
            path.addLine(to: CGPoint(x: 16.5, y: 4.0))
            path.addLine(to: CGPoint(x: 16.5, y: 7.0))
            path.move(to: CGPoint(x: 16.5, y: 13.0))
            path.addLine(to: CGPoint(x: 16.5, y: 16.0))
            path.addLine(to: CGPoint(x: 13.5, y: 16.0))
            path.move(to: CGPoint(x: 6.5, y: 16.0))
            path.addLine(to: CGPoint(x: 3.5, y: 16.0))
            path.addLine(to: CGPoint(x: 3.5, y: 13.0))
            path.move(to: CGPoint(x: 6.5, y: 8.5))
            path.addLine(to: CGPoint(x: 13.5, y: 8.5))
            path.move(to: CGPoint(x: 6.5, y: 11.7))
            path.addLine(to: CGPoint(x: 11.8, y: 11.7))
        case .translate:
            // Bilingual 文 (top-left) / A (bottom-right)
            path.move(to: CGPoint(x: 6.4, y: 3.3))
            path.addLine(to: CGPoint(x: 6.4, y: 5.0))
            path.move(to: CGPoint(x: 3.3, y: 5.4))
            path.addLine(to: CGPoint(x: 9.5, y: 5.4))
            path.move(to: CGPoint(x: 8.0, y: 5.4))
            path.addLine(to: CGPoint(x: 4.0, y: 11.2))
            path.move(to: CGPoint(x: 4.8, y: 6.5))
            path.addLine(to: CGPoint(x: 8.8, y: 10.7))

            path.move(to: CGPoint(x: 10.6, y: 16.5))
            path.addLine(to: CGPoint(x: 13.8, y: 8.4))
            path.addLine(to: CGPoint(x: 17.0, y: 16.5))
            path.move(to: CGPoint(x: 11.7, y: 13.8))
            path.addLine(to: CGPoint(x: 15.9, y: 13.8))
        case .pin:
            path.move(to: CGPoint(x: 6.6, y: 3.5))
            path.addLine(to: CGPoint(x: 13.4, y: 3.5))
            path.move(to: CGPoint(x: 7.6, y: 3.5))
            path.addLine(to: CGPoint(x: 7.9, y: 8.0))
            path.addLine(to: CGPoint(x: 5.3, y: 11.8))
            path.addLine(to: CGPoint(x: 14.7, y: 11.8))
            path.addLine(to: CGPoint(x: 12.1, y: 8.0))
            path.addLine(to: CGPoint(x: 12.4, y: 3.5))
            path.move(to: CGPoint(x: 10, y: 11.8))
            path.addLine(to: CGPoint(x: 10, y: 16.5))
        case .save:
            path.move(to: CGPoint(x: 10, y: 3.5))
            path.addLine(to: CGPoint(x: 10, y: 12.2))
            path.move(to: CGPoint(x: 6.6, y: 8.9))
            path.addLine(to: CGPoint(x: 10, y: 12.4))
            path.addLine(to: CGPoint(x: 13.4, y: 8.9))
            path.move(to: CGPoint(x: 4.0, y: 12.6))
            path.addLine(to: CGPoint(x: 4.0, y: 15.8))
            path.addLine(to: CGPoint(x: 16.0, y: 15.8))
            path.addLine(to: CGPoint(x: 16.0, y: 12.6))
        case .close:
            path.move(to: CGPoint(x: 5, y: 5))
            path.addLine(to: CGPoint(x: 15, y: 15))
            path.move(to: CGPoint(x: 15, y: 5))
            path.addLine(to: CGPoint(x: 5, y: 15))
        case .done:
            path.move(to: CGPoint(x: 4.5, y: 10.5))
            path.addLine(to: CGPoint(x: 8.3, y: 14.3))
            path.addLine(to: CGPoint(x: 15.5, y: 6.1))
        case .copy:
            path.addRoundedRect(
                in: CGRect(x: 7.5, y: 7.5, width: 9.0, height: 9.0), cornerSize: CGSize(width: 1.8, height: 1.8))
            path.move(to: CGPoint(x: 5.5, y: 12.5))
            path.addLine(to: CGPoint(x: 4.8, y: 12.5))
            path.addQuadCurve(to: CGPoint(x: 3.5, y: 11.2), control: CGPoint(x: 3.5, y: 12.5))
            path.addLine(to: CGPoint(x: 3.5, y: 4.8))
            path.addQuadCurve(to: CGPoint(x: 4.8, y: 3.5), control: CGPoint(x: 3.5, y: 3.5))
            path.addLine(to: CGPoint(x: 11.2, y: 3.5))
            path.addQuadCurve(to: CGPoint(x: 12.5, y: 4.8), control: CGPoint(x: 12.5, y: 3.5))
            path.addLine(to: CGPoint(x: 12.5, y: 5.5))
        case .zoomMini:
            path.addEllipse(in: CGRect(x: 4.0, y: 4.0, width: 9.6, height: 9.6))
            path.move(to: CGPoint(x: 12.3, y: 12.3))
            path.addLine(to: CGPoint(x: 16.2, y: 16.2))
        case .opacityMini:
            path.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 13, height: 13))
        }
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
    }

    private func fillPath(scale: CGFloat) -> Path? {
        var path = Path()
        switch kind {
        case .rect:
            let corners = [
                CGPoint(x: 3.5, y: 4.5),
                CGPoint(x: 16.5, y: 4.5),
                CGPoint(x: 3.5, y: 15.5),
                CGPoint(x: 16.5, y: 15.5),
            ]
            for pt in corners {
                path.addEllipse(in: CGRect(x: pt.x - 1.2, y: pt.y - 1.2, width: 2.4, height: 2.4))
            }
        case .pen:
            path.move(to: CGPoint(x: 10, y: 3.5))
            path.addLine(to: CGPoint(x: 7.9, y: 9.5))
            path.addLine(to: CGPoint(x: 12.1, y: 9.5))
            path.closeSubpath()
        case .opacityMini:
            path.move(to: CGPoint(x: 10, y: 3.5))
            path.addArc(
                center: CGPoint(x: 10, y: 10),
                radius: 6.5,
                startAngle: .degrees(-90),
                endAngle: .degrees(90),
                clockwise: true)
            path.closeSubpath()
        default:
            return nil
        }
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private enum ToolbarIndicatorKey: Hashable {
    case rect
    case arrow
    case pen
    case ocr
    case translate
}

private struct ToolbarIndicatorCenterKey: PreferenceKey {
    static let defaultValue: [ToolbarIndicatorKey: CGFloat] = [:]
    static func reduce(value: inout [ToolbarIndicatorKey: CGFloat], nextValue: () -> [ToolbarIndicatorKey: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SceneOverlayToolbarView: View {
    @ObservedObject var model: TranslationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var indicatorCenters: [ToolbarIndicatorKey: CGFloat] = [:]

    private let shellSpaceName = "SceneToolbarShellSpace"

    var body: some View {
        let session = model.sceneSession
        let activeTool = session?.activeTool ?? .none
        let translationActive = session?.translationActive ?? false
        let hasSubBar =
            activeTool != .none
            || translationActive
            || (session?.ocrRunning ?? false)
            || (session?.errorMessage != nil)
        let cornerRadius: CGFloat = hasSubBar ? 20 : 22

        VStack(spacing: 0) {
            AppleTranslationHostView(coordinator: model.appleCoordinator)
                .frame(width: 0, height: 0)

            row1(session: session)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            if let session, hasSubBar {
                hairlineWithIndicator(activeKey: activeIndicatorKey(for: session))
                row2(session: session)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
        .coordinateSpace(name: shellSpaceName)
        .onPreferenceChange(ToolbarIndicatorCenterKey.self) { centers in
            indicatorCenters = centers
        }
        .modifier(OverlayGlassModifier(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.24), radius: 14, y: 5)
    }

    @ViewBuilder
    private func row1(session: TranslationSceneSession?) -> some View {
        let activeTool = session?.activeTool ?? .none
        let translationActive = session?.translationActive ?? false
        let annotationsEmpty = session?.annotations.isEmpty ?? true
        let busyOCR = session?.ocrRunning ?? false
        let busyTrans = session?.translating ?? false

        HStack(spacing: 4) {
            toolButton(
                kind: .rect,
                key: .rect,
                active: activeTool == .rectangle,
                help: "矩形标注"
            ) {
                model.selectAnnotationTool(activeTool == .rectangle ? .none : .rectangle)
            }
            toolButton(
                kind: .arrow,
                key: .arrow,
                active: activeTool == .arrow,
                help: "箭头标注"
            ) {
                model.selectAnnotationTool(activeTool == .arrow ? .none : .arrow)
            }
            toolButton(
                kind: .pen,
                key: .pen,
                active: activeTool == .pen,
                help: "画笔标注"
            ) {
                model.selectAnnotationTool(activeTool == .pen ? .none : .pen)
            }
            iconButton(
                kind: .undo,
                active: false,
                disabled: annotationsEmpty,
                help: "撤销标注 (⌘Z)"
            ) {
                model.undoAnnotation()
            }

            toolbarDivider

            toolButton(
                kind: .ocr,
                key: .ocr,
                active: busyOCR,
                disabled: busyOCR || busyTrans,
                help: "识别文字并复制"
            ) {
                model.triggerSceneOCR()
            }
            toolButton(
                kind: .translate,
                key: .translate,
                active: activeTool == .none && translationActive,
                help: "翻译选区"
            ) {
                model.toggleSceneTranslation()
            }

            toolbarDivider

            iconButton(
                kind: .pin,
                active: false,
                disabled: session == nil,
                help: "钉住为桌面贴图"
            ) {
                model.pinSceneSticker()
            }
            iconButton(
                kind: .save,
                active: false,
                disabled: session == nil,
                help: "保存图片 (⌘S)"
            ) {
                model.saveSceneImage()
            }
            iconButton(
                kind: .close,
                active: false,
                disabled: false,
                help: "关闭 (Esc)"
            ) {
                model.cancelCaptureOverlay()
            }
            Button {
                model.finishAndCopyImage()
            } label: {
                ScreenshotVectorIcon(kind: .done)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(session == nil)
            .help("完成并复制图片 (回车 / ⌘C)")
            .accessibilityLabel("完成并复制图片")
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

    private func toolButton(
        kind: ScreenshotVectorIconKind,
        key: ToolbarIndicatorKey,
        active: Bool,
        disabled: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        iconButton(kind: kind, active: active, disabled: disabled, help: help, action: action)
            .background(indicatorAnchor(key))
    }

    private func indicatorAnchor(_ key: ToolbarIndicatorKey) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ToolbarIndicatorCenterKey.self,
                value: [key: geo.frame(in: .named(shellSpaceName)).midX])
        }
    }

    private func iconButton(
        kind: ScreenshotVectorIconKind,
        active: Bool,
        disabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ScreenshotVectorIcon(kind: kind)
                .foregroundStyle(
                    disabled
                        ? Color.primary.opacity(0.28)
                        : (active ? Color.accentColor : Color.primary.opacity(0.86))
                )
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func activeIndicatorKey(for session: TranslationSceneSession) -> ToolbarIndicatorKey? {
        if session.ocrRunning {
            return .ocr
        }
        switch session.activeTool {
        case .rectangle: return .rect
        case .arrow: return .arrow
        case .pen: return .pen
        case .none: return session.translationActive ? .translate : nil
        }
    }

    @ViewBuilder
    private func hairlineWithIndicator(activeKey: ToolbarIndicatorKey?) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .overlay(alignment: .leading) {
                if let activeKey, let centerX = indicatorCenters[activeKey] {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(x: centerX, y: 0.5)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: activeKey)
                }
            }
    }

    @ViewBuilder
    private func row2(session: TranslationSceneSession) -> some View {
        if session.ocrRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在识别文字…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if session.activeTool != .none {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(AnnotationStrokeSize.allCases) { strokeSize in
                        let selected = session.activeStrokeSize == strokeSize
                        Button {
                            model.selectAnnotationStrokeSize(strokeSize)
                        } label: {
                            ZStack {
                                if selected {
                                    Circle()
                                        .fill(Color.primary.opacity(0.09))
                                        .frame(width: 24, height: 24)
                                }
                                Circle()
                                    .fill(Color.primary.opacity(selected ? 0.88 : 0.45))
                                    .frame(width: strokeSize.indicatorDiameter, height: strokeSize.indicatorDiameter)
                            }
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(strokeHelp(strokeSize))
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 16)

                HStack(spacing: 8) {
                    ForEach(AnnotationColor.applePalette) { color in
                        let selected = session.activeColor == color
                        Button {
                            model.selectAnnotationColor(color)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(red: color.r, green: color.g, blue: color.b))
                                    .frame(width: 14, height: 14)
                                if selected {
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                                        .frame(width: 20, height: 20)
                                }
                            }
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(color.name)
                    }
                }
            }
        } else if session.translationActive {
            if session.translating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在翻译…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let error = session.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(error)
            } else {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(TranslationTargetLanguage.allCases) { target in
                            Button {
                                model.switchTargetLanguage(target)
                            } label: {
                                if model.preferences.targetLanguage == target {
                                    Text("✓ \(target.title)")
                                } else {
                                    Text(target.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.preferences.targetLanguage.shortTitle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("切换目标语种")

                    Button {
                        model.toggleSceneComparison()
                    } label: {
                        Text("对照")
                            .font(.callout)
                            .foregroundStyle(session.showingComparison ? Color.accentColor : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(
                                session.showingComparison
                                    ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.translatedImage == nil)
                    .help("切换显示原图 / 译文（空格键）")

                    Button {
                        model.copyTranslatedText()
                    } label: {
                        Text(session.toastMessage ?? "复制译文")
                            .font(.callout)
                            .foregroundStyle(session.toastMessage != nil ? Color.accentColor : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("复制识别译文")
                }
            }
        } else if let error = session.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(error)
        }
    }

    private func strokeHelp(_ size: AnnotationStrokeSize) -> String {
        switch size {
        case .thin: "细线条"
        case .medium: "中线条"
        case .thick: "粗线条"
        }
    }
}

@MainActor
private final class PinnedStickerViewModel: ObservableObject {
    let originalImage: CGImage
    let annotations: [ScreenshotAnnotation]
    let scaleFactor: CGFloat
    let appleCoordinator = AppleSystemTranslationCoordinator()
    private weak var model: TranslationModel?
    private weak var hudState: StickerHUDState?
    private var ocrTask: Task<Void, Never>?
    private var ocrGeneration: UInt64 = 0
    private var translateTask: Task<Void, Never>?
    private var translateGeneration: UInt64 = 0

    @Published var translatedImage: CGImage?
    @Published var showOriginal: Bool
    @Published var ocrBusy = false
    @Published var translatingBusy = false
    @Published private(set) var activeCGImage: CGImage

    init(session: TranslationSceneSession, model: TranslationModel, hudState: StickerHUDState) {
        let initialShowOriginal =
            session.translatedImage == nil || !session.translationActive || session.showingComparison
        self.originalImage = session.originalImage
        self.annotations = session.annotations
        self.scaleFactor = session.scaleFactor
        self.translatedImage = session.translatedImage
        self.showOriginal = initialShowOriginal
        self.activeCGImage = SceneImageRenderer.renderComposite(
            original: session.originalImage,
            translated: session.translatedImage,
            showTranslation: !initialShowOriginal,
            annotations: session.annotations,
            scaleFactor: session.scaleFactor)
        self.model = model
        self.hudState = hudState
    }

    var isShowingTranslation: Bool {
        translatedImage != nil && !showOriginal
    }

    func copyCurrentImage() {
        model?.copyImageDirect(activeCGImage)
        hudState?.showToast("已复制图片")
    }

    func saveCurrentImage() {
        guard let model else { return }
        switch model.saveImageDirect(activeCGImage) {
        case .saved(let url):
            hudState?.showToast("已保存 \(url.lastPathComponent)")
        case .cancelled:
            break
        case .failed(let message):
            hudState?.showToast(message)
        }
    }

    func triggerOCR() {
        guard !ocrBusy, let model else { return }
        ocrTask?.cancel()
        ocrGeneration &+= 1
        let token = ocrGeneration
        ocrBusy = true
        let imageToScan = activeCGImage
        ocrTask = Task { @MainActor [weak self, weak model] in
            defer {
                if let self, self.ocrGeneration == token {
                    self.ocrBusy = false
                    self.ocrTask = nil
                }
            }
            guard let model else { return }
            do {
                _ = try await model.ocrImageDirect(imageToScan)
                guard !Task.isCancelled, let self, self.ocrGeneration == token else { return }
                self.hudState?.showToast("已复制文字")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.ocrGeneration == token else { return }
                self.hudState?.showToast(error.localizedDescription)
            }
        }
    }

    func triggerTranslateOrToggle() {
        if translatedImage != nil {
            showOriginal.toggle()
            rebuildActiveCGImage()
            return
        }
        guard !translatingBusy, let model else { return }
        translateTask?.cancel()
        translateGeneration &+= 1
        let token = translateGeneration
        translatingBusy = true
        let raw = originalImage
        let coordinator = appleCoordinator
        translateTask = Task { @MainActor [weak self, weak model] in
            defer {
                if let self, self.translateGeneration == token {
                    self.translatingBusy = false
                    self.translateTask = nil
                }
            }
            guard let model else { return }
            do {
                let rendered = try await model.translateImageDirect(
                    raw,
                    localTranslator: model.isPreviewMode ? nil : coordinator)
                guard !Task.isCancelled, let self, self.translateGeneration == token else { return }
                self.translatedImage = rendered
                self.showOriginal = false
                self.rebuildActiveCGImage()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.translateGeneration == token else { return }
                self.hudState?.showToast(error.localizedDescription)
            }
        }
    }

    func cancelAllTasks() {
        ocrGeneration &+= 1
        translateGeneration &+= 1
        ocrTask?.cancel()
        ocrTask = nil
        translateTask?.cancel()
        translateTask = nil
        ocrBusy = false
        translatingBusy = false
        appleCoordinator.cancelAll()
        hudState?.cancelAll()
    }

    private func rebuildActiveCGImage() {
        activeCGImage = SceneImageRenderer.renderComposite(
            original: originalImage,
            translated: translatedImage,
            showTranslation: !showOriginal,
            annotations: annotations,
            scaleFactor: scaleFactor)
    }
}

private struct PinnedStickerContent: View {
    @ObservedObject var viewModel: PinnedStickerViewModel
    @ObservedObject var hudState: StickerHUDState
    let onClose: () -> Void
    let onOverlayBarResolve: @MainActor (NSView?) -> Void

    @State private var hovering = false

    var body: some View {
        let cgImage = viewModel.activeCGImage
        Image(decorative: cgImage, scale: 1.0)
            .resizable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0.45), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .overlay {
                AppleTranslationHostView(coordinator: viewModel.appleCoordinator)
                    .frame(width: 0, height: 0)
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    stickerOverlayBar
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = hudState.toastText {
                    Text(toast)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .modifier(OverlayCapsuleGlassModifier())
                        .padding(.bottom, 10)
                } else if let kind = hudState.hudKind {
                    HStack(spacing: 5) {
                        ScreenshotVectorIcon(
                            kind: kind == .zoom ? .zoomMini : .opacityMini,
                            size: 14)
                        Text("\(hudState.hudPercent)%")
                            .font(.caption.monospacedDigit().weight(.medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .modifier(OverlayCapsuleGlassModifier())
                    .padding(.bottom, 10)
                }
            }
            .onHover { hovering = $0 }
    }

    private var stickerOverlayBar: some View {
        let translateLabel =
            viewModel.translatedImage != nil ? (viewModel.showOriginal ? "显示译文" : "对照原图") : "翻译贴图"
        let translateSelected = viewModel.isShowingTranslation || viewModel.translatingBusy
        return HStack(spacing: 4) {
            Button {
                viewModel.triggerOCR()
            } label: {
                ScreenshotVectorIcon(kind: .ocr)
                    .foregroundStyle(viewModel.ocrBusy ? Color.accentColor : Color.primary.opacity(0.86))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.ocrBusy)
            .help("识别文字并复制")
            .accessibilityLabel("识别文字并复制")
            .accessibilityAddTraits(viewModel.ocrBusy ? .isSelected : [])

            Button {
                viewModel.triggerTranslateOrToggle()
            } label: {
                ScreenshotVectorIcon(kind: .translate)
                    .foregroundStyle(
                        translateSelected
                            ? Color.accentColor : Color.primary.opacity(0.86)
                    )
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.translatingBusy)
            .help(translateLabel)
            .accessibilityLabel(translateLabel)
            .accessibilityAddTraits(translateSelected ? .isSelected : [])

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)

            Button {
                viewModel.copyCurrentImage()
            } label: {
                ScreenshotVectorIcon(kind: .copy)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制图片 (⌘C)")
            .accessibilityLabel("复制图片")

            Button {
                viewModel.saveCurrentImage()
            } label: {
                ScreenshotVectorIcon(kind: .save)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("保存图片 (⌘S)")
            .accessibilityLabel("保存图片")

            Button(action: onClose) {
                ScreenshotVectorIcon(kind: .close)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭贴图 (Esc)")
            .accessibilityLabel("关闭贴图")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .modifier(OverlayCapsuleGlassModifier())
        .background(StickerOverlayBarAnchor(onResolve: onOverlayBarResolve))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }
}

private struct OverlayGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }
}

private struct OverlayCapsuleGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }
}
