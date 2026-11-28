// [INPUT]: CapturedScreenSnapshot、TranslationSceneSession、TranslationModel 与 AppKit/SwiftUI。
// [OUTPUT]: 全屏聚焦框选窗口协调器（OverlayKeyWindow、ScreenshotOverlayController）。
// [POS]: 截图插件的窗口生命周期边界；装配画布、A2 工具条与独立桌面贴图，自身不直接绘制图形。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
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
