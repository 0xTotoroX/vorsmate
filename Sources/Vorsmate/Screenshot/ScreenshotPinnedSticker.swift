// [INPUT]: TranslationModel、TranslationSceneSession、SceneImageRenderer 与 AppKit/SwiftUI。
// [OUTPUT]: 独立桌面悬浮贴图窗口、滚轮/捏合缩放、Alt+滚轮透明度、HUD 轻提示与悬停操作条。
// [POS]: 钉住后脱离截图全屏遮罩独立运行的浮动 NSPanel 视图与模型。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import CoreGraphics
import SwiftUI
import VorsmateCore
import VorsmateSystem

@MainActor
final class StickerHUDState: ObservableObject {
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

final class PinnedStickerHostingView<Content: View>: NSHostingView<Content> {
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

final class PinnedStickerWindow: NSPanel {
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
final class PinnedStickerViewModel: ObservableObject {
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

struct PinnedStickerContent: View {
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
