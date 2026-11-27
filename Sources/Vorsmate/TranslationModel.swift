// [INPUT]: TranslationPreferences、屏幕捕获与识别驱动、全局热键中心、按源隔离密钥存储、双语翻译服务及叠层协议。
// [OUTPUT]: 截图工作流状态机；编排框选叠层、矢量标注、按需 OCR／原场景译文回填与纯图标桌面贴图。
// [POS]: VorsmatePlugin 实现；禁用时不持有热键或叠层窗口，密钥仅存本机非同步钥匙串并按服务源隔离。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import CoreGraphics
import Foundation
import VorsmateCore
import VorsmateSystem

struct TranslationSceneSession: Equatable {
    var screenFrame: CGRect
    var selectionScreenRect: CGRect
    var scaleFactor: CGFloat
    var originalImage: CGImage
    var translatedImage: CGImage?
    var regions: [TranslatedTextRegion]
    var annotations: [ScreenshotAnnotation] = []
    var activeTool: ScreenshotTool = .none
    var activeColor: AnnotationColor = .defaultColor
    var activeStrokeSize: AnnotationStrokeSize = .medium
    var translationActive = false
    var showingComparison = false
    var translating = false
    var ocrRunning = false
    var sourceText = ""
    var translatedText = ""
    var toastMessage: String?
    var errorMessage: String?
    private(set) var compositeImage: CGImage

    init(
        screenFrame: CGRect,
        selectionScreenRect: CGRect,
        scaleFactor: CGFloat,
        originalImage: CGImage,
        translatedImage: CGImage? = nil,
        regions: [TranslatedTextRegion] = [],
        annotations: [ScreenshotAnnotation] = [],
        activeTool: ScreenshotTool = .none,
        activeColor: AnnotationColor = .defaultColor,
        activeStrokeSize: AnnotationStrokeSize = .medium,
        translationActive: Bool = false,
        showingComparison: Bool = false,
        translating: Bool = false,
        ocrRunning: Bool = false,
        sourceText: String = "",
        translatedText: String = "",
        toastMessage: String? = nil,
        errorMessage: String? = nil
    ) {
        self.screenFrame = screenFrame
        self.selectionScreenRect = selectionScreenRect
        self.scaleFactor = scaleFactor
        self.originalImage = originalImage
        self.translatedImage = translatedImage
        self.regions = regions
        self.annotations = annotations
        self.activeTool = activeTool
        self.activeColor = activeColor
        self.activeStrokeSize = activeStrokeSize
        self.translationActive = translationActive
        self.showingComparison = showingComparison
        self.translating = translating
        self.ocrRunning = ocrRunning
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.toastMessage = toastMessage
        self.errorMessage = errorMessage
        self.compositeImage = SceneImageRenderer.renderComposite(
            original: originalImage,
            translated: translatedImage,
            showTranslation: translationActive && !showingComparison,
            annotations: annotations,
            scaleFactor: scaleFactor)
    }

    mutating func rebuildCompositeImage() {
        compositeImage = SceneImageRenderer.renderComposite(
            original: originalImage,
            translated: translatedImage,
            showTranslation: translationActive && !showingComparison,
            annotations: annotations,
            scaleFactor: scaleFactor)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.screenFrame == rhs.screenFrame
            && lhs.selectionScreenRect == rhs.selectionScreenRect
            && lhs.scaleFactor == rhs.scaleFactor
            && lhs.originalImage === rhs.originalImage
            && lhs.translatedImage === rhs.translatedImage
            && lhs.regions == rhs.regions
            && lhs.annotations == rhs.annotations
            && lhs.activeTool == rhs.activeTool
            && lhs.activeColor == rhs.activeColor
            && lhs.activeStrokeSize == rhs.activeStrokeSize
            && lhs.translationActive == rhs.translationActive
            && lhs.showingComparison == rhs.showingComparison
            && lhs.translating == rhs.translating
            && lhs.ocrRunning == rhs.ocrRunning
            && lhs.sourceText == rhs.sourceText
            && lhs.translatedText == rhs.translatedText
            && lhs.toastMessage == rhs.toastMessage
            && lhs.errorMessage == rhs.errorMessage
            && lhs.compositeImage === rhs.compositeImage
    }
}

@MainActor
final class TranslationModel: ObservableObject, VorsmatePlugin {
    let id = PluginID.translate

    @Published var preferences: TranslationPreferences
    @Published var sourceText = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var busy = false
    @Published private(set) var translating = false
    @Published private(set) var ocrRunning = false
    @Published private(set) var overlayActive = false
    @Published private(set) var sceneSession: TranslationSceneSession?
    @Published private(set) var feedbackMessage: String?
    @Published private(set) var feedbackIsError = false
    @Published private(set) var needsScreenCapturePermission = false
    @Published private(set) var hotKeyConflict: String?
    @Published private(set) var active = false

    let appleCoordinator = AppleSystemTranslationCoordinator()

    var onPrepareScreenshot: (() -> Void)?

    var isPreviewMode: Bool { preview }
    var currentCredentialScope: String? { preferences.apiConfig.credentialScope }
    var apiKeyRequired: Bool { !preferences.apiConfig.allowsEmptyAPIKey }

    private let preview: Bool
    private let captureDriver: any TranslationCaptureDriver
    private let hotKeys: any TranslationHotKeyRegistrar
    private let apiKeyStore: any TranslationAPIKeyStore
    private let localTranslator: any LocalSystemTranslator
    private let openAITranslator: OpenAICompatibleTranslator
    private let persist: (TranslationPreferences) throws -> Void
    private let screenshotDelay: Duration
    private var overlayPresenter: (any ScreenshotOverlayPresenting)?
    private var workTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var workGeneration: UInt64 = 0
    private var sceneGeneration: UInt64 = 0

    var statusText: String {
        if !active { return "未启用" }
        if busy || translating || ocrRunning { return "处理中…" }
        if hotKeyConflict != nil { return "快捷键冲突" }
        if overlayActive { return "截图中" }
        return "待命"
    }

    init(
        preview: Bool,
        preferences: TranslationPreferences = TranslationPreferences(),
        captureDriver: (any TranslationCaptureDriver)? = nil,
        hotKeys: (any TranslationHotKeyRegistrar)? = nil,
        apiKeyStore: (any TranslationAPIKeyStore)? = nil,
        localTranslator: (any LocalSystemTranslator)? = nil,
        openAITranslator: OpenAICompatibleTranslator = OpenAICompatibleTranslator(),
        overlayPresenter: (any ScreenshotOverlayPresenting)? = nil,
        screenshotDelay: Duration? = nil,
        persist: @escaping (TranslationPreferences) throws -> Void = { _ in }
    ) {
        self.preview = preview
        self.preferences = preferences
        self.captureDriver =
            captureDriver ?? (preview ? PreviewTranslationCaptureDriver() : SystemTranslationCaptureDriver())
        self.hotKeys = hotKeys ?? (preview ? NoopHotKeyRegistrar() : CarbonHotKeyCenter())
        let store =
            apiKeyStore
            ?? (preview
                ? InMemoryTranslationAPIKeyStore(initialKeys: ["https://api.openai.com": "preview-key"])
                : KeychainTranslationAPIKeyStore())
        self.apiKeyStore = store
        self.hasAPIKey = preferences.apiConfig.credentialScope.map { store.hasAPIKey(forScope: $0) } ?? false
        self.localTranslator = localTranslator ?? (preview ? PreviewSystemTranslator() : self.appleCoordinator)
        self.openAITranslator = openAITranslator
        self.overlayPresenter = overlayPresenter
        self.screenshotDelay = screenshotDelay ?? (preview ? .zero : .milliseconds(120))
        self.persist = persist
    }

    func activate() {
        guard !active else { return }
        active = true
        applyHotKeys()
    }

    func deactivate() {
        lifecycleGeneration &+= 1
        workGeneration &+= 1
        sceneGeneration &+= 1
        workTask?.cancel()
        workTask = nil
        toastTask?.cancel()
        toastTask = nil
        appleCoordinator.cancelAll()
        busy = false
        translating = false
        ocrRunning = false
        hotKeys.unregisterAll()
        overlayPresenter?.closeAll()
        overlayActive = false
        sceneSession = nil
        hotKeyConflict = nil
        feedbackMessage = nil
        feedbackIsError = false
        needsScreenCapturePermission = false
        active = false
    }

    func refresh() {
        guard active else { return }
        syncScreenCapturePermission()
        refreshAPIKeyStatus()
    }

    func panelDidChangeVisibility(_ visible: Bool) {
        guard active, visible else { return }
        syncScreenCapturePermission()
        refreshAPIKeyStatus()
    }

    func reloadPreferences(_ next: TranslationPreferences) {
        preferences = next
        refreshAPIKeyStatus()
        if active { applyHotKeys() }
    }

    func updatePreferences(_ next: TranslationPreferences) {
        do {
            try persist(next)
            preferences = next
            refreshAPIKeyStatus()
            if feedbackIsError {
                feedbackMessage = nil
                feedbackIsError = false
            }
            if active { applyHotKeys() }
        } catch {
            setFeedback(error.localizedDescription, isError: true)
        }
    }

    @discardableResult
    func saveAPIKey(_ rawKey: String) -> Bool {
        guard let scope = currentCredentialScope else {
            setFeedback("请先填写有效的接口地址。", isError: true)
            return false
        }
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setFeedback("接口密钥不能为空。", isError: true)
            return false
        }
        do {
            try apiKeyStore.saveAPIKey(trimmed, forScope: scope)
            refreshAPIKeyStatus()
            setFeedback("密钥已安全保存至本机钥匙串", isError: false)
            return true
        } catch {
            setFeedback(error.localizedDescription, isError: true)
            return false
        }
    }

    func deleteAPIKey() {
        guard let scope = currentCredentialScope else {
            setFeedback("请先填写有效的接口地址。", isError: true)
            return
        }
        do {
            try apiKeyStore.deleteAPIKey(forScope: scope)
            refreshAPIKeyStatus()
            setFeedback("已删除模型密钥", isError: false)
        } catch {
            setFeedback(error.localizedDescription, isError: true)
        }
    }

    func applyProviderPreset(_ preset: OpenAIProviderPreset) {
        var next = preferences
        next.engine = .openAICompatible
        next.apiConfig = preset.config
        updatePreferences(next)
        retranslateActiveContext()
    }

    func switchEngine(_ engine: TranslationEngine) {
        guard preferences.engine != engine else { return }
        var next = preferences
        next.engine = engine
        updatePreferences(next)
        retranslateActiveContext()
    }

    func switchTargetLanguage(_ target: TranslationTargetLanguage) {
        guard preferences.targetLanguage != target else { return }
        var next = preferences
        next.targetLanguage = target
        updatePreferences(next)
        retranslateActiveContext()
    }

    func triggerScreenshot() {
        guard active, !busy else { return }
        let token = beginNewWork()
        let capturedLifecycle = lifecycleGeneration
        toastTask?.cancel()
        toastTask = nil
        busy = true
        translating = false
        ocrRunning = false
        feedbackMessage = nil
        feedbackIsError = false
        if captureDriver.hasScreenCapturePermission() {
            needsScreenCapturePermission = false
        }
        onPrepareScreenshot?()

        let delay = screenshotDelay
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.workGeneration == token {
                    self.busy = false
                    self.workTask = nil
                }
            }
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token
                else { return }

                let snapshots = try await self.captureDriver.captureScreens(
                    excludingWindowNumbers: self.excludedWindowNumbers())
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token
                else { return }

                self.needsScreenCapturePermission = false
                self.sceneGeneration &+= 1
                self.sceneSession = nil
                let overlay = self.ensureOverlayPresenter()
                overlay.beginCapture(snapshots: snapshots)
                self.overlayActive = overlay.isActive
            } catch is CancellationError {
                return
            } catch TranslationCaptureError.cancelled {
                return
            } catch {
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token
                else { return }
                if (error as? TranslationCaptureError) == .permissionDenied {
                    self.needsScreenCapturePermission = true
                }
                self.setFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    func triggerScreenshotTranslate() {
        triggerScreenshot()
    }

    func beginSelectionInteraction() {
        _ = beginNewWork()
        toastTask?.cancel()
        toastTask = nil
        translating = false
        ocrRunning = false
        if var session = sceneSession {
            session.translating = false
            session.ocrRunning = false
            session.toastMessage = nil
            session.errorMessage = nil
            sceneSession = session
            overlayPresenter?.updateSceneState(session)
        }
    }

    func completeScreenSelection(snapshot: CapturedScreenSnapshot, selectionScreenRect: CGRect) {
        sceneGeneration &+= 1
        _ = beginNewWork()
        toastTask?.cancel()
        toastTask = nil
        translating = false
        ocrRunning = false
        guard
            let cropped = SceneImageRenderer.crop(
                image: snapshot.image, screenFrame: snapshot.screenFrame, selectionScreenRect: selectionScreenRect)
        else {
            cancelCaptureOverlay()
            return
        }

        let session = TranslationSceneSession(
            screenFrame: snapshot.screenFrame,
            selectionScreenRect: selectionScreenRect,
            scaleFactor: snapshot.scaleFactor,
            originalImage: cropped)
        sourceText = ""
        translatedText = ""
        feedbackMessage = nil
        feedbackIsError = false
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
    }

    func updateSelectionRect(snapshot: CapturedScreenSnapshot, selectionScreenRect: CGRect) {
        sceneGeneration &+= 1
        _ = beginNewWork()
        toastTask?.cancel()
        toastTask = nil
        translating = false
        ocrRunning = false
        guard
            let cropped = SceneImageRenderer.crop(
                image: snapshot.image, screenFrame: snapshot.screenFrame, selectionScreenRect: selectionScreenRect)
        else {
            return
        }

        let currentTool = sceneSession?.activeTool ?? .none
        let currentColor = sceneSession?.activeColor ?? .defaultColor
        let currentStrokeSize = sceneSession?.activeStrokeSize ?? .medium

        let updated = TranslationSceneSession(
            screenFrame: snapshot.screenFrame,
            selectionScreenRect: selectionScreenRect,
            scaleFactor: snapshot.scaleFactor,
            originalImage: cropped,
            activeTool: currentTool,
            activeColor: currentColor,
            activeStrokeSize: currentStrokeSize)
        sourceText = ""
        translatedText = ""
        sceneSession = updated
        overlayPresenter?.updateSceneState(updated)
    }

    func selectAnnotationTool(_ tool: ScreenshotTool) {
        guard var session = sceneSession else { return }
        session.activeTool = tool
        session.errorMessage = nil
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
    }

    func selectAnnotationColor(_ color: AnnotationColor) {
        guard var session = sceneSession else { return }
        session.activeColor = color
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
    }

    func selectAnnotationStrokeSize(_ size: AnnotationStrokeSize) {
        guard var session = sceneSession else { return }
        session.activeStrokeSize = size
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
    }

    func addAnnotation(_ annotation: ScreenshotAnnotation) {
        guard var session = sceneSession else { return }
        session.annotations.append(annotation)
        session.rebuildCompositeImage()
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
    }

    func undoAnnotation() {
        guard var session = sceneSession, !session.annotations.isEmpty else { return }
        session.annotations.removeLast()
        session.rebuildCompositeImage()
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
    }

    func triggerSceneOCR() {
        guard var session = sceneSession, !session.ocrRunning, !session.translating else { return }
        let token = beginNewWork()
        let capturedLifecycle = lifecycleGeneration
        let capturedSceneGen = sceneGeneration
        session.activeTool = .none
        session.ocrRunning = true
        session.errorMessage = nil
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
        ocrRunning = true
        feedbackMessage = nil
        feedbackIsError = false
        let targetImage = session.originalImage

        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.workGeneration == token {
                    self.ocrRunning = false
                    self.workTask = nil
                }
            }
            do {
                let ocr = try await self.captureDriver.recognizeRegions(
                    in: targetImage, mergeLineBreaks: self.preferences.mergeOCRLineBreaks)
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token,
                    self.sceneGeneration == capturedSceneGen
                else { return }

                if var current = self.sceneSession {
                    current.sourceText = ocr.combinedText
                    self.sceneSession = current
                }
                self.sourceText = ocr.combinedText
                self.captureDriver.writeClipboardText(ocr.combinedText)
                self.setFeedback("OCR 已复制进剪贴板", isError: false)
                self.toastTask?.cancel()
                self.toastTask = nil
                self.sceneGeneration &+= 1
                self.sceneSession = nil
                self.overlayPresenter?.closeCaptureOverlayOnly()
                self.overlayActive = self.overlayPresenter?.isActive ?? false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token,
                    self.sceneGeneration == capturedSceneGen
                else { return }
                if var current = self.sceneSession {
                    current.ocrRunning = false
                    current.errorMessage = error.localizedDescription
                    self.sceneSession = current
                    self.overlayPresenter?.updateSceneState(current)
                }
                self.setFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    func toggleSceneTranslation() {
        guard var session = sceneSession else { return }
        session.activeTool = .none
        session.errorMessage = nil

        if session.translationActive {
            if session.translating {
                _ = beginNewWork()
                translating = false
                session.translating = false
            }
            session.translationActive = false
            session.showingComparison = false
            session.rebuildCompositeImage()
            sceneSession = session
            overlayPresenter?.updateSceneState(session)
            return
        }

        session.translationActive = true
        session.showingComparison = false

        if session.translatedImage != nil {
            session.rebuildCompositeImage()
            sceneSession = session
            overlayPresenter?.updateSceneState(session)
            return
        }

        runSceneTranslation(with: session)
    }

    func toggleSceneComparison() {
        guard var session = sceneSession, session.translationActive, !session.translating,
            session.translatedImage != nil
        else { return }
        session.showingComparison.toggle()
        session.rebuildCompositeImage()
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
    }

    func copyTranslatedText() {
        let trimmed = (sceneSession?.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setFeedback("没有可复制的译文。", isError: true)
            return
        }
        captureDriver.writeClipboardText(trimmed)
        setFeedback("已复制译文", isError: false)
        showSceneToast("已复制译文")
    }

    func finishAndCopyImage() {
        guard let session = sceneSession else { return }
        captureDriver.writeClipboardImage(session.compositeImage)
        setFeedback("已复制图片", isError: false)
        cancelCaptureOverlay()
    }

    func saveSceneImage() {
        guard let session = sceneSession else { return }
        let image = session.compositeImage
        overlayPresenter?.setCaptureOverlayVisible(false)
        let result = captureDriver.saveImageToFile(image, suggestedName: Self.defaultScreenshotFileName())
        switch result {
        case .saved(let url):
            setFeedback("已保存至 \(url.lastPathComponent)", isError: false)
            cancelCaptureOverlay()
        case .cancelled:
            overlayPresenter?.setCaptureOverlayVisible(true)
            overlayActive = overlayPresenter?.isActive ?? false
        case .failed(let message):
            overlayPresenter?.setCaptureOverlayVisible(true)
            overlayActive = overlayPresenter?.isActive ?? false
            if var current = sceneSession {
                current.errorMessage = message
                sceneSession = current
                overlayPresenter?.updateSceneState(current)
            }
            setFeedback(message, isError: true)
        }
    }

    func pinSceneSticker() {
        guard var session = sceneSession else { return }
        sceneGeneration &+= 1
        _ = beginNewWork()
        toastTask?.cancel()
        toastTask = nil
        translating = false
        ocrRunning = false
        session.activeTool = .none
        session.translating = false
        session.ocrRunning = false
        session.toastMessage = nil
        session.errorMessage = nil
        sceneSession = nil
        overlayPresenter?.pinCurrentScene(session)
        overlayActive = overlayPresenter?.isActive ?? false
    }

    func handleEscapeKey() {
        if var session = sceneSession, session.activeTool != .none {
            session.activeTool = .none
            sceneSession = session
            overlayPresenter?.updateSceneState(session)
            return
        }
        cancelCaptureOverlay()
    }

    func cancelCaptureOverlay() {
        sceneGeneration &+= 1
        _ = beginNewWork()
        toastTask?.cancel()
        toastTask = nil
        translating = false
        ocrRunning = false
        sceneSession = nil
        overlayPresenter?.closeCaptureOverlayOnly()
        overlayActive = overlayPresenter?.isActive ?? false
    }

    func copyImageDirect(_ image: CGImage) {
        captureDriver.writeClipboardImage(image)
        setFeedback("已复制图片", isError: false)
    }

    @discardableResult
    func saveImageDirect(_ image: CGImage) -> ImageSaveResult {
        let result = captureDriver.saveImageToFile(image, suggestedName: Self.defaultScreenshotFileName())
        switch result {
        case .saved(let url):
            setFeedback("已保存至 \(url.lastPathComponent)", isError: false)
        case .cancelled:
            break
        case .failed(let message):
            setFeedback(message, isError: true)
        }
        return result
    }

    func ocrImageDirect(_ image: CGImage) async throws -> String {
        let capturedLifecycle = lifecycleGeneration
        try Task.checkCancellation()
        guard active, lifecycleGeneration == capturedLifecycle else {
            throw CancellationError()
        }

        let ocr = try await captureDriver.recognizeRegions(
            in: image, mergeLineBreaks: preferences.mergeOCRLineBreaks)
        try Task.checkCancellation()
        guard active, lifecycleGeneration == capturedLifecycle else {
            throw CancellationError()
        }

        captureDriver.writeClipboardText(ocr.combinedText)
        setFeedback("OCR 已复制进剪贴板", isError: false)
        return ocr.combinedText
    }

    func translateImageDirect(
        _ image: CGImage,
        localTranslator overrideTranslator: (any LocalSystemTranslator)? = nil
    ) async throws -> CGImage {
        let capturedLifecycle = lifecycleGeneration
        try Task.checkCancellation()
        guard active, lifecycleGeneration == capturedLifecycle else {
            throw CancellationError()
        }

        let ocr = try await captureDriver.recognizeRegions(
            in: image, mergeLineBreaks: preferences.mergeOCRLineBreaks)
        try Task.checkCancellation()
        guard active, lifecycleGeneration == capturedLifecycle else {
            throw CancellationError()
        }

        let translatedLines = try await translateTexts(
            ocr.regions.map(\.text),
            combinedContext: ocr.combinedText,
            localTranslatorOverride: overrideTranslator)
        try Task.checkCancellation()
        guard active, lifecycleGeneration == capturedLifecycle else {
            throw CancellationError()
        }

        let translatedRegions = zip(ocr.regions, translatedLines).map { region, target in
            TranslatedTextRegion(
                original: region.text,
                translated: target.isEmpty ? region.text : target,
                normalizedBox: region.normalizedBox)
        }
        return SceneImageRenderer.render(original: image, regions: translatedRegions)
    }

    func openPreviewSampleSticker() {
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let sampleImage = PreviewTranslationCaptureDriver.makeSampleImage(width: 720, height: 440)
        let size = CGSize(width: 360, height: 220)
        let selectionRect = CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height)
        let sampleSession = TranslationSceneSession(
            screenFrame: screenFrame,
            selectionScreenRect: selectionRect,
            scaleFactor: 2,
            originalImage: sampleImage)
        ensureOverlayPresenter().pinCurrentScene(sampleSession)
    }

    func openScreenCaptureSettings() {
        _ = captureDriver.requestScreenCapturePermission()
        captureDriver.openScreenCaptureSettings()
    }

    private func runSceneTranslation(with session: TranslationSceneSession) {
        let token = beginNewWork()
        let capturedLifecycle = lifecycleGeneration
        let capturedSceneGen = sceneGeneration
        var starting = session
        starting.translating = true
        starting.errorMessage = nil
        sceneSession = starting
        overlayPresenter?.updateSceneState(starting)
        translating = true
        feedbackMessage = nil
        feedbackIsError = false
        let targetImage = starting.originalImage

        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.workGeneration == token {
                    self.translating = false
                    self.workTask = nil
                }
            }
            do {
                let ocr = try await self.captureDriver.recognizeRegions(
                    in: targetImage, mergeLineBreaks: self.preferences.mergeOCRLineBreaks)
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token,
                    self.sceneGeneration == capturedSceneGen
                else { return }

                self.sourceText = ocr.combinedText
                if var current = self.sceneSession {
                    current.sourceText = ocr.combinedText
                    self.sceneSession = current
                }

                let translatedLines = try await self.translateTexts(
                    ocr.regions.map(\.text), combinedContext: ocr.combinedText)
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token,
                    self.sceneGeneration == capturedSceneGen
                else { return }

                let translatedRegions = zip(ocr.regions, translatedLines).map { region, target in
                    TranslatedTextRegion(
                        original: region.text,
                        translated: target.isEmpty ? region.text : target,
                        normalizedBox: region.normalizedBox)
                }
                let rendered = SceneImageRenderer.render(original: targetImage, regions: translatedRegions)
                let joinedTranslation = translatedLines.joined(separator: "\n")
                self.translatedText = joinedTranslation

                if var current = self.sceneSession {
                    current.regions = translatedRegions
                    current.translatedImage = rendered
                    current.sourceText = ocr.combinedText
                    current.translatedText = joinedTranslation
                    current.translating = false
                    current.errorMessage = nil
                    current.rebuildCompositeImage()
                    self.sceneSession = current
                    self.overlayPresenter?.updateSceneState(current)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token,
                    self.sceneGeneration == capturedSceneGen
                else { return }
                if var current = self.sceneSession {
                    current.translating = false
                    current.errorMessage = error.localizedDescription
                    self.sceneSession = current
                    self.overlayPresenter?.updateSceneState(current)
                }
                self.setFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    private func retranslateActiveContext() {
        guard var session = sceneSession, session.translationActive else { return }
        if session.regions.isEmpty {
            runSceneTranslation(with: session)
            return
        }

        let token = beginNewWork()
        let capturedLifecycle = lifecycleGeneration
        let capturedSceneGen = sceneGeneration
        session.translating = true
        session.errorMessage = nil
        sceneSession = session
        overlayPresenter?.updateSceneState(session)
        translating = true
        let originals = session.regions.map(\.original)
        let baseRegions = session.regions
        let targetImage = session.originalImage
        let contextText = session.sourceText.isEmpty ? originals.joined(separator: "\n") : session.sourceText

        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.workGeneration == token {
                    self.translating = false
                    self.workTask = nil
                }
            }
            do {
                let translatedLines = try await self.translateTexts(originals, combinedContext: contextText)
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token,
                    self.sceneGeneration == capturedSceneGen
                else { return }

                let updatedRegions = zip(baseRegions, translatedLines).map { region, target in
                    TranslatedTextRegion(
                        original: region.original,
                        translated: target.isEmpty ? region.original : target,
                        normalizedBox: region.normalizedBox)
                }
                let rendered = SceneImageRenderer.render(original: targetImage, regions: updatedRegions)
                let joinedTranslation = translatedLines.joined(separator: "\n")
                self.translatedText = joinedTranslation

                if var current = self.sceneSession {
                    current.regions = updatedRegions
                    current.translatedImage = rendered
                    current.translatedText = joinedTranslation
                    current.translating = false
                    current.errorMessage = nil
                    current.rebuildCompositeImage()
                    self.sceneSession = current
                    self.overlayPresenter?.updateSceneState(current)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == capturedLifecycle,
                    self.workGeneration == token,
                    self.sceneGeneration == capturedSceneGen
                else { return }
                if var current = self.sceneSession {
                    current.translating = false
                    current.errorMessage = error.localizedDescription
                    self.sceneSession = current
                    self.overlayPresenter?.updateSceneState(current)
                }
                self.setFeedback(error.localizedDescription, isError: true)
            }
        }
    }

    private func showSceneToast(_ message: String) {
        guard var session = sceneSession else { return }
        toastTask?.cancel()
        session.toastMessage = message
        sceneSession = session
        overlayPresenter?.updateSceneState(session)

        let capturedLifecycle = lifecycleGeneration
        let capturedSceneGen = sceneGeneration
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled,
                let self,
                self.lifecycleGeneration == capturedLifecycle,
                self.sceneGeneration == capturedSceneGen,
                var current = self.sceneSession,
                current.toastMessage == message
            else { return }
            current.toastMessage = nil
            self.sceneSession = current
            self.overlayPresenter?.updateSceneState(current)
            self.toastTask = nil
        }
    }

    private func translateTexts(
        _ texts: [String],
        combinedContext: String,
        localTranslatorOverride: (any LocalSystemTranslator)? = nil
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let pair = TranslationLanguageDetector.detectAndResolve(
            for: combinedContext, target: preferences.targetLanguage)

        switch preferences.engine {
        case .apple:
            let translator = localTranslatorOverride ?? localTranslator
            return try await translator.translateBatch(texts, sourceCode: pair.source, targetCode: pair.target)
        case .openAICompatible:
            guard let scope = preferences.apiConfig.credentialScope else {
                throw TranslationServiceError.invalidEndpoint
            }
            let key = try apiKeyStore.loadAPIKey(forScope: scope) ?? ""
            return try await openAITranslator.translateBatch(
                texts,
                source: pair.source,
                target: pair.target,
                config: preferences.apiConfig,
                apiKey: key)
        }
    }

    private func beginNewWork() -> UInt64 {
        workTask?.cancel()
        workTask = nil
        workGeneration &+= 1
        busy = false
        ocrRunning = false
        translating = false
        return workGeneration
    }

    private func refreshAPIKeyStatus() {
        guard let scope = currentCredentialScope else {
            hasAPIKey = false
            return
        }
        hasAPIKey = apiKeyStore.hasAPIKey(forScope: scope)
    }

    private func excludedWindowNumbers() -> [Int] {
        overlayPresenter?.windowNumbers ?? []
    }

    private func ensureOverlayPresenter() -> any ScreenshotOverlayPresenting {
        if let overlayPresenter { return overlayPresenter }
        let created = ScreenshotOverlayController(model: self)
        overlayPresenter = created
        return created
    }

    private func syncScreenCapturePermission() {
        guard needsScreenCapturePermission, captureDriver.hasScreenCapturePermission() else { return }
        needsScreenCapturePermission = false
        if feedbackIsError, feedbackMessage == TranslationCaptureError.permissionDenied.errorDescription {
            feedbackMessage = nil
            feedbackIsError = false
        }
    }

    private func applyHotKeys() {
        let conflicts = hotKeys.apply(screenshot: preferences.screenshotShortcut) { [weak self] action in
            self?.handleHotKey(action)
        }
        if conflicts.isEmpty {
            hotKeyConflict = nil
        } else {
            let names = conflicts.map { action -> String in
                switch action {
                case .screenshot: "截图(\(preferences.screenshotShortcut.displayTitle))"
                }
            }
            hotKeyConflict = "快捷键被其他应用占用：" + names.joined(separator: "、")
        }
    }

    private func handleHotKey(_ action: TranslationHotKeyAction) {
        guard active else { return }
        switch action {
        case .screenshot: triggerScreenshot()
        }
    }

    private func setFeedback(_ message: String, isError: Bool) {
        feedbackMessage = message
        feedbackIsError = isError
    }

    private static func defaultScreenshotFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Vorsmate-截图-\(formatter.string(from: Date())).png"
    }
}
