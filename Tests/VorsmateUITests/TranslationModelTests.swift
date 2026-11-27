// [INPUT]: TranslationModel 与可控异步内存替身（截图识别、热键、按源隔离密钥存储、系统/模型翻译与叠层呈现器）。
// [OUTPUT]: 单入口截图生命周期、并发代次取消隔离、按源密钥隔离、Ollama 免密钥、贴图直出隔离、保存恢复及标注回归。
// [POS]: UI 层截图状态机测试，不捕获真实屏幕、不访问网络或钥匙串。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import CoreGraphics
import Foundation
import Testing
import VorsmateCore
import VorsmateSystem

@testable import Vorsmate

@Suite("截图插件状态机")
@MainActor
struct TranslationModelTests {
    @Test("默认未启用不注册热键，激活幂等，停用立即释放热键与叠层")
    func lifecycleAndStatusText() async {
        let hotKeys = MockHotKeyRegistrar()
        let overlay = MockOverlayPresenter()
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: hotKeys,
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: PreviewSystemTranslator(),
            overlayPresenter: overlay,
            screenshotDelay: .zero)

        #expect(!model.active)
        #expect(model.statusText == "未启用")
        #expect(hotKeys.applyCount == 0)

        model.activate()
        model.activate()
        #expect(model.active)
        #expect(model.statusText == "待命")
        #expect(hotKeys.applyCount == 1)

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        #expect(model.statusText == "截图中")
        #expect(overlay.beganCaptureSnapshots.count == 1)

        model.deactivate()
        #expect(!model.active)
        #expect(hotKeys.unregisterCount == 1)
        #expect(overlay.closeAllCount == 1)
        #expect(!model.overlayActive)
        #expect(model.sceneSession == nil)
        #expect(model.statusText == "未启用")

        hotKeys.conflicts = [.screenshot]
        model.activate()
        #expect(model.statusText == "快捷键冲突")
        #expect(model.hotKeyConflict != nil)
    }

    @Test("框选后不自动翻译，支持工具选择、标注增撤、Esc 退回工具及选区重调清旧状态")
    func selectionAnnotationsAndEscapeFlow() async throws {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        let overlay = MockOverlayPresenter()
        var preparedCount = 0

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: PreviewSystemTranslator(),
            overlayPresenter: overlay,
            screenshotDelay: .zero)
        model.onPrepareScreenshot = { preparedCount += 1 }
        model.activate()

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        #expect(preparedCount == 1)

        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))
        let session = try #require(model.sceneSession)
        #expect(!session.translationActive)
        #expect(!session.translating)
        #expect(session.translatedImage == nil)
        #expect(session.regions.isEmpty)
        #expect(session.activeTool == .none)
        #expect(session.compositeImage === session.originalImage)
        #expect(capture.recognizeCount == 0)

        let customColor = AnnotationColor.applePalette[3]
        model.selectAnnotationTool(.rectangle)
        model.selectAnnotationColor(customColor)
        model.selectAnnotationStrokeSize(.thick)
        #expect(model.sceneSession?.compositeImage === session.compositeImage)
        let rectAnnotation = ScreenshotAnnotation(
            kind: .rectangle(rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3)),
            color: customColor,
            size: .thick)
        let arrowAnnotation = ScreenshotAnnotation(
            kind: .arrow(start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.8, y: 0.7)),
            color: customColor,
            size: .thick)
        model.addAnnotation(rectAnnotation)
        let afterFirstAnnotation = try #require(model.sceneSession?.compositeImage)
        #expect(afterFirstAnnotation !== session.originalImage)
        model.addAnnotation(arrowAnnotation)
        #expect(model.sceneSession?.annotations.count == 2)

        model.undoAnnotation()
        #expect(model.sceneSession?.annotations == [rectAnnotation])
        #expect(model.sceneSession?.compositeImage !== afterFirstAnnotation)

        model.handleEscapeKey()
        #expect(model.sceneSession?.activeTool == ScreenshotTool.none)
        #expect(model.overlayActive)

        model.updateSelectionRect(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 80, y: 80, width: 320, height: 200))
        let updated = try #require(model.sceneSession)
        #expect(updated.selectionScreenRect == CGRect(x: 80, y: 80, width: 320, height: 200))
        #expect(updated.annotations.isEmpty)
        #expect(updated.regions.isEmpty)
        #expect(updated.translatedImage == nil)
        #expect(!updated.translationActive)

        model.handleEscapeKey()
        #expect(!model.overlayActive)
        #expect(model.sceneSession == nil)
    }

    @Test("纯 OCR 复制文本并关闭叠层；失败时清空工具并保留叠层展示错误")
    func pureOCROverlayAndFailureFlow() async throws {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        capture.recognizedRegions = [
            RecognizedTextRegion(
                text: "+ New Conversation", normalizedBox: CGRect(x: 0.1, y: 0.68, width: 0.5, height: 0.1)),
            RecognizedTextRegion(text: "Automations", normalizedBox: CGRect(x: 0.1, y: 0.45, width: 0.35, height: 0.1)),
        ]
        let overlay = MockOverlayPresenter()

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: PreviewSystemTranslator(),
            overlayPresenter: overlay,
            screenshotDelay: .zero)
        model.activate()

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))
        model.selectAnnotationTool(.rectangle)

        capture.recognizeError = TranslationCaptureError.noTextDetected
        model.triggerSceneOCR()
        await waitUntil { !model.ocrRunning && model.sceneSession?.ocrRunning == false }
        #expect(model.overlayActive)
        #expect(model.sceneSession?.activeTool == ScreenshotTool.none)
        #expect(model.sceneSession?.errorMessage == TranslationCaptureError.noTextDetected.errorDescription)
        #expect(overlay.closeCaptureOnlyCount == 0)

        capture.recognizeError = nil
        model.triggerSceneOCR()
        await waitUntil { !model.ocrRunning && !model.overlayActive }
        #expect(capture.writtenClipboards.last == "+ New Conversation Automations")
        #expect(model.feedbackMessage == "OCR 已复制进剪贴板")
        #expect(!model.feedbackIsError)
        #expect(overlay.closeCaptureOnlyCount == 1)
    }

    @Test("按需翻译切换、对照模式、DeepSeek 预设、译文复制与无损合成复制")
    func onDemandTranslationDeepSeekPresetAndCompositeCopy() async throws {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        capture.recognizedRegions = [
            RecognizedTextRegion(text: "Automations", normalizedBox: CGRect(x: 0.1, y: 0.45, width: 0.35, height: 0.1))
        ]
        let keyStore = InMemoryTranslationAPIKeyStore()
        let transport = MockModelHTTPTransport { request in
            let body = #"{"choices":[{"message":{"content":"自动化（DeepSeek）"}}]}"#
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://api.deepseek.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!
            )
        }
        let openAITranslator = OpenAICompatibleTranslator(transport: transport)
        let overlay = MockOverlayPresenter()

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: keyStore,
            localTranslator: PreviewSystemTranslator(),
            openAITranslator: openAITranslator,
            overlayPresenter: overlay,
            screenshotDelay: .zero)
        model.activate()

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))
        model.selectAnnotationTool(.arrow)

        model.toggleSceneTranslation()
        await waitUntil { !(model.sceneSession?.translating ?? true) && model.sceneSession?.translatedImage != nil }

        let translatedSession = try #require(model.sceneSession)
        #expect(translatedSession.activeTool == .none)
        #expect(translatedSession.translationActive)
        #expect(translatedSession.regions.map(\.translated) == ["自动化"])
        #expect(translatedSession.compositeImage === translatedSession.translatedImage)
        #expect(translatedSession.translatedText == "自动化")

        model.toggleSceneComparison()
        #expect(model.sceneSession?.showingComparison == true)
        #expect(model.sceneSession?.compositeImage === translatedSession.originalImage)
        model.toggleSceneComparison()
        #expect(model.sceneSession?.showingComparison == false)
        #expect(model.sceneSession?.compositeImage === translatedSession.translatedImage)

        model.copyTranslatedText()
        #expect(capture.writtenClipboards.last == "自动化")
        #expect(model.sceneSession?.toastMessage == "已复制译文")

        model.applyProviderPreset(.deepseek)
        #expect(model.preferences.engine == .openAICompatible)
        #expect(model.preferences.apiConfig == OpenAIProviderPreset.deepseek.config)
        #expect(model.apiKeyRequired)
        await waitUntil { !model.translating && model.sceneSession?.errorMessage != nil }
        #expect(model.sceneSession?.errorMessage == TranslationServiceError.missingAPIKey.errorDescription)

        model.saveAPIKey("sk-deepseek-test")
        #expect(model.hasAPIKey)
        model.switchTargetLanguage(.simplifiedChinese)
        await waitUntil { !model.translating && model.sceneSession?.translatedText == "自动化（DeepSeek）" }
        #expect(transport.recordedRequests.last?.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")

        model.finishAndCopyImage()
        #expect(capture.writtenImagesCount == 1)
        #expect(!model.overlayActive)
    }

    @Test("saveAPIKey 返回成功与否；beginNewWork 主动复位繁忙标志")
    func saveAPIKeyReturnValueAndBusyFlagReset() async throws {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: PreviewSystemTranslator(),
            overlayPresenter: MockOverlayPresenter(),
            screenshotDelay: .zero)
        model.activate()

        #expect(!model.saveAPIKey("   "))
        #expect(!model.hasAPIKey)

        var invalidPrefs = model.preferences
        invalidPrefs.apiConfig.baseURL = "http://example.com"
        model.updatePreferences(invalidPrefs)
        #expect(!model.saveAPIKey("sk-invalid-url"))

        model.applyProviderPreset(.deepseek)
        #expect(model.saveAPIKey("  sk-valid-key  "))
        #expect(model.hasAPIKey)

        let captureSuspension = AsyncSuspension()
        capture.captureSuspension = captureSuspension
        model.triggerScreenshot()
        await waitUntil { model.busy }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))
        #expect(!model.busy)
        #expect(!model.ocrRunning)
        #expect(!model.translating)
        captureSuspension.resume()
        await Task.yield()
    }

    @Test("保存 OpenAI 密钥后切到 DeepSeek 不会泄漏旧密钥；Ollama 免密钥直接发送且无 Authorization 头")
    func credentialScopeIsolationAndOllamaKeyless() async throws {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        capture.recognizedRegions = [
            RecognizedTextRegion(text: "Automations", normalizedBox: CGRect(x: 0.1, y: 0.45, width: 0.35, height: 0.1))
        ]
        let keyStore = InMemoryTranslationAPIKeyStore()
        let transport = MockModelHTTPTransport { request in
            let body = #"{"choices":[{"message":{"content":"自动化"}}]}"#
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url ?? URL(string: "http://127.0.0.1:11434/v1/chat/completions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!
            )
        }
        let openAITranslator = OpenAICompatibleTranslator(transport: transport)
        let overlay = MockOverlayPresenter()

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: keyStore,
            localTranslator: PreviewSystemTranslator(),
            openAITranslator: openAITranslator,
            overlayPresenter: overlay,
            screenshotDelay: .zero)
        model.activate()

        model.applyProviderPreset(.openAI)
        model.saveAPIKey("sk-openai-secret")
        #expect(model.hasAPIKey)
        #expect(model.apiKeyRequired)

        model.applyProviderPreset(.deepseek)
        #expect(!model.hasAPIKey)
        #expect(model.apiKeyRequired)

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))
        model.toggleSceneTranslation()
        await waitUntil { !model.translating && model.sceneSession?.errorMessage != nil }
        #expect(model.sceneSession?.errorMessage == TranslationServiceError.missingAPIKey.errorDescription)
        #expect(transport.recordedRequests.isEmpty)

        model.applyProviderPreset(.ollama)
        #expect(!model.hasAPIKey)
        #expect(!model.apiKeyRequired)
        await waitUntil { !model.translating && model.sceneSession?.translatedImage != nil }
        #expect(model.sceneSession?.errorMessage == nil)
        let ollamaRequest = try #require(transport.recordedRequests.last)
        #expect(ollamaRequest.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        #expect(ollamaRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("贴图钉住与保存结果分支（失败与取消恢复叠层且保留标注，成功关闭叠层）")
    func stickerPinDirectActionsAndSaveResultBranches() async throws {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        capture.recognizedRegions = [
            RecognizedTextRegion(text: "Automations", normalizedBox: CGRect(x: 0.1, y: 0.45, width: 0.35, height: 0.1))
        ]
        let overlay = MockOverlayPresenter()

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: PreviewSystemTranslator(),
            overlayPresenter: overlay,
            screenshotDelay: .zero)
        model.activate()

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))
        let pen = ScreenshotAnnotation(
            kind: .pen(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)]),
            color: .defaultColor,
            size: .medium)
        model.addAnnotation(pen)

        model.pinSceneSticker()
        #expect(overlay.pinnedSessions.count == 1)
        #expect(overlay.pinnedSessions.first?.annotations == [pen])
        #expect(overlay.pinnedSessions.first?.translatedImage == nil)
        #expect(!model.overlayActive)

        let directImage = PreviewTranslationCaptureDriver.makeSampleImage(width: 240, height: 160)
        model.copyImageDirect(directImage)
        #expect(capture.writtenImagesCount == 1)

        #expect(model.saveImageDirect(directImage) != .cancelled)
        #expect(capture.savedImagesCount == 1)

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))
        model.addAnnotation(pen)

        capture.saveResult = .failed("磁盘空间不足")
        capture.onSaveImage = {
            #expect(overlay.visibilityHistory.last == false)
        }
        model.saveSceneImage()
        #expect(model.overlayActive)
        #expect(overlay.visibilityHistory.suffix(2) == [false, true])
        #expect(model.sceneSession?.annotations == [pen])
        #expect(model.sceneSession?.errorMessage == "磁盘空间不足")
        #expect(model.feedbackIsError)

        capture.saveResult = .cancelled
        model.saveSceneImage()
        #expect(model.overlayActive)
        #expect(overlay.visibilityHistory.suffix(2) == [false, true])
        #expect(model.sceneSession?.annotations == [pen])

        capture.saveResult = nil
        model.saveSceneImage()
        #expect(capture.savedImagesCount == 2)
        #expect(!model.overlayActive)
        #expect(model.sceneSession == nil)

        model.openPreviewSampleSticker()
        #expect(overlay.pinnedSessions.count == 2)
    }

    @Test("OCR 任务 A 被新截图 B 取代后 A 不清理 B，deactivate 仍能取消 B 且不重开叠层")
    func ocrTaskGenerationIsolationAndDeactivateCancellation() async {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        capture.recognizedRegions = [
            RecognizedTextRegion(text: "Automations", normalizedBox: CGRect(x: 0.1, y: 0.45, width: 0.35, height: 0.1))
        ]
        let overlay = MockOverlayPresenter()

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: PreviewSystemTranslator(),
            overlayPresenter: overlay,
            screenshotDelay: .zero)
        model.activate()

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))

        let ocrSuspension = AsyncSuspension()
        capture.recognizeSuspension = ocrSuspension
        model.triggerSceneOCR()
        await waitUntil { capture.recognizeCount == 1 && model.ocrRunning }

        let captureSuspension = AsyncSuspension()
        capture.captureSuspension = captureSuspension
        model.triggerScreenshot()
        await waitUntil { model.busy && !model.ocrRunning }
        #expect(model.busy)

        ocrSuspension.resume()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.busy)
        #expect(capture.writtenClipboards.isEmpty)

        model.deactivate()
        #expect(!model.active)
        #expect(!model.busy)

        let countBeforeResume = overlay.beganCaptureSnapshots.count
        captureSuspension.resume()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!model.overlayActive)
        #expect(overlay.beganCaptureSnapshots.count == countBeforeResume)
    }

    @Test("贴图直出任务在途时停用抛出 CancellationError 且不写剪贴板，也不污染当前会话译文")
    func stickerDirectCancellationAndSessionIsolation() async throws {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        capture.recognizedRegions = [
            RecognizedTextRegion(text: "Automations", normalizedBox: CGRect(x: 0.1, y: 0.45, width: 0.35, height: 0.1))
        ]
        let overlay = MockOverlayPresenter()
        let localTranslator = ControllableLocalTranslator()

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: localTranslator,
            overlayPresenter: overlay,
            screenshotDelay: .zero)
        model.activate()

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))
        localTranslator.nextResult = ["会话译文"]
        model.toggleSceneTranslation()
        await waitUntil { model.sceneSession?.translatedImage != nil }
        #expect(model.sceneSession?.translatedText == "会话译文")

        let stickerImage = PreviewTranslationCaptureDriver.makeSampleImage(width: 200, height: 120)
        localTranslator.nextResult = ["贴图译文"]
        let renderedSticker = try await model.translateImageDirect(stickerImage)
        #expect(renderedSticker.width == 200)
        #expect(model.sceneSession?.translatedText == "会话译文")
        #expect(model.translatedText == "会话译文")

        let ocrSuspension = AsyncSuspension()
        capture.recognizeSuspension = ocrSuspension
        let ocrTask = Task { @MainActor in
            try await model.ocrImageDirect(stickerImage)
        }
        await waitUntil { ocrSuspension.isWaiting }
        model.deactivate()
        ocrSuspension.resume()

        var ocrCancelled = false
        do {
            _ = try await ocrTask.value
        } catch is CancellationError {
            ocrCancelled = true
        }
        #expect(ocrCancelled)
        #expect(capture.writtenClipboards.isEmpty)

        model.activate()
        let translateSuspension = AsyncSuspension()
        localTranslator.suspension = translateSuspension
        let translateTask = Task { @MainActor in
            try await model.translateImageDirect(stickerImage)
        }
        await waitUntil { translateSuspension.isWaiting }
        model.deactivate()
        translateSuspension.resume()

        var translateCancelled = false
        do {
            _ = try await translateTask.value
        } catch is CancellationError {
            translateCancelled = true
        }
        #expect(translateCancelled)
    }

    @Test("beginSelectionInteraction 立即取消在途翻译与 OCR 并清理进行中状态")
    func beginSelectionInteractionCancelsInFlightWork() async throws {
        let capture = MockCaptureDriver()
        let snapshot = makeSnapshot()
        capture.snapshots = [snapshot]
        capture.recognizedRegions = [
            RecognizedTextRegion(text: "Automations", normalizedBox: CGRect(x: 0.1, y: 0.45, width: 0.35, height: 0.1))
        ]
        let overlay = MockOverlayPresenter()
        let localTranslator = ControllableLocalTranslator()
        let translateSuspension = AsyncSuspension()
        localTranslator.suspension = translateSuspension
        localTranslator.nextResult = ["不应写入的译文"]

        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: localTranslator,
            overlayPresenter: overlay,
            screenshotDelay: .zero)
        model.activate()

        model.triggerScreenshot()
        await waitUntil { model.overlayActive }
        model.completeScreenSelection(
            snapshot: snapshot, selectionScreenRect: CGRect(x: 40, y: 40, width: 420, height: 280))

        model.toggleSceneTranslation()
        await waitUntil { model.translating && translateSuspension.isWaiting }

        model.beginSelectionInteraction()
        #expect(!model.translating)
        #expect(!model.ocrRunning)
        let session = try #require(model.sceneSession)
        #expect(!session.translating)
        #expect(!session.ocrRunning)
        #expect(session.errorMessage == nil)

        translateSuspension.resume()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.sceneSession?.translatedImage == nil)
    }

    @Test("缺少录屏权限时显示引导入口，授权并在刷新后清除错误提示")
    func screenCapturePermissionFlow() async {
        let capture = MockCaptureDriver()
        capture.hasPermission = false
        capture.captureError = TranslationCaptureError.permissionDenied
        let model = TranslationModel(
            preview: true,
            captureDriver: capture,
            hotKeys: MockHotKeyRegistrar(),
            apiKeyStore: InMemoryTranslationAPIKeyStore(),
            localTranslator: PreviewSystemTranslator(),
            overlayPresenter: MockOverlayPresenter(),
            screenshotDelay: .zero)
        model.activate()

        model.triggerScreenshot()
        await waitUntil { !model.busy }
        #expect(model.needsScreenCapturePermission)
        #expect(model.feedbackIsError)
        #expect(model.feedbackMessage == TranslationCaptureError.permissionDenied.errorDescription)

        model.openScreenCaptureSettings()
        #expect(capture.requestPermissionCount == 1)
        #expect(capture.openSettingsCount == 1)

        capture.hasPermission = true
        model.refresh()
        #expect(!model.needsScreenCapturePermission)
        #expect(model.feedbackMessage == nil)
        #expect(!model.feedbackIsError)
    }

    private func makeSnapshot() -> CapturedScreenSnapshot {
        CapturedScreenSnapshot(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            scaleFactor: 2,
            image: PreviewTranslationCaptureDriver.makeSampleImage(width: 1600, height: 1200),
            windowRects: [CGRect(x: 60, y: 80, width: 320, height: 220)])
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<120 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class AsyncSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        let cont = continuation
        continuation = nil
        cont?.resume()
    }
}

@MainActor
private final class ControllableLocalTranslator: LocalSystemTranslator {
    var suspension: AsyncSuspension?
    var nextResult: [String] = ["译文"]

    func translateBatch(_ texts: [String], sourceCode: String, targetCode: String) async throws -> [String] {
        if let suspension {
            self.suspension = nil
            await suspension.wait()
        }
        try Task.checkCancellation()
        return texts.indices.map { idx in
            idx < nextResult.count ? nextResult[idx] : "[译] \(texts[idx])"
        }
    }
}

@MainActor
private final class MockCaptureDriver: TranslationCaptureDriver {
    var hasPermission = true
    var requestPermissionCount = 0
    var openSettingsCount = 0
    var snapshots: [CapturedScreenSnapshot] = []
    var captureError: Error?
    var captureSuspension: AsyncSuspension?
    var recognizedRegions: [RecognizedTextRegion] = []
    var recognizeError: Error?
    var recognizeSuspension: AsyncSuspension?
    var recognizeCount = 0
    var clipboardText: String?
    var writtenClipboards: [String] = []
    var writtenImagesCount = 0
    var savedImagesCount = 0
    var saveResult: ImageSaveResult?
    var onSaveImage: (@MainActor () -> Void)?

    func hasScreenCapturePermission() -> Bool { hasPermission }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        requestPermissionCount += 1
        return hasPermission
    }

    func openScreenCaptureSettings() {
        openSettingsCount += 1
    }

    func captureScreens(excludingWindowNumbers: [Int]) async throws -> [CapturedScreenSnapshot] {
        if let suspension = captureSuspension {
            captureSuspension = nil
            await suspension.wait()
        }
        try Task.checkCancellation()
        if let captureError { throw captureError }
        return snapshots
    }

    func recognizeRegions(
        in image: CGImage, mergeLineBreaks: Bool
    ) async throws -> (regions: [RecognizedTextRegion], combinedText: String) {
        recognizeCount += 1
        if let suspension = recognizeSuspension {
            recognizeSuspension = nil
            await suspension.wait()
        }
        try Task.checkCancellation()
        if let recognizeError { throw recognizeError }
        let combined = TranslationTextNormalizer.normalize(
            recognizedRegions.map(\.text).joined(separator: "\n"),
            mergeLineBreaks: mergeLineBreaks)
        return (recognizedRegions, combined)
    }

    func readClipboardText() -> String? { clipboardText }

    func writeClipboardText(_ text: String) {
        clipboardText = text
        writtenClipboards.append(text)
    }

    func writeClipboardImage(_ image: CGImage) {
        writtenImagesCount += 1
    }

    func saveImageToFile(_ image: CGImage, suggestedName: String) -> ImageSaveResult {
        onSaveImage?()
        if let saveResult {
            return saveResult
        }
        savedImagesCount += 1
        return .saved(FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName))
    }
}

@MainActor
private final class MockHotKeyRegistrar: TranslationHotKeyRegistrar {
    var applyCount = 0
    var unregisterCount = 0
    var conflicts: [TranslationHotKeyAction] = []
    private var handler: (@MainActor (TranslationHotKeyAction) -> Void)?

    func apply(
        screenshot: TranslationShortcut,
        handler: @escaping @MainActor (TranslationHotKeyAction) -> Void
    ) -> [TranslationHotKeyAction] {
        applyCount += 1
        self.handler = handler
        return conflicts
    }

    func unregisterAll() {
        unregisterCount += 1
    }
}

@MainActor
private final class MockOverlayPresenter: ScreenshotOverlayPresenting {
    var isActive = false
    var windowNumbers: [Int] = []
    var beganCaptureSnapshots: [[CapturedScreenSnapshot]] = []
    var updatedSessions: [TranslationSceneSession?] = []
    var pinnedSessions: [TranslationSceneSession] = []
    var visibilityHistory: [Bool] = []
    var closeCaptureOnlyCount = 0
    var closeAllCount = 0

    func beginCapture(snapshots: [CapturedScreenSnapshot]) {
        isActive = true
        beganCaptureSnapshots.append(snapshots)
    }

    func updateSceneState(_ session: TranslationSceneSession?) {
        updatedSessions.append(session)
    }

    func pinCurrentScene(_ session: TranslationSceneSession) {
        isActive = false
        pinnedSessions.append(session)
    }

    func setCaptureOverlayVisible(_ visible: Bool) {
        isActive = visible
        visibilityHistory.append(visible)
    }

    func closeCaptureOverlayOnly() {
        closeCaptureOnlyCount += 1
        isActive = false
    }

    func closeAll() {
        closeAllCount += 1
        isActive = false
    }
}

private final class MockModelHTTPTransport: OpenAITranslationTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    var recordedRequests: [URLRequest] {
        lock.withLock { requests }
    }

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            requests.append(request)
        }
        return try handler(request)
    }
}
