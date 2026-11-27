// [INPUT]: TranslationPolicy、ScreenshotAnnotation、SceneImageRenderer、PreviewTranslationCaptureDriver 与 OpenAICompatibleTranslator。
// [OUTPUT]: 快捷键、服务商预设、标注模型、选区几何、标注/合成渲染及批量模型接口回归。
// [POS]: Core/System 截图与翻译逻辑测试，不请求网络、不采集屏幕、不读写系统钥匙串。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
import Darwin
import Foundation
import Testing
import VorsmateCore
import VorsmateSystem

@Suite("截图策略、标注几何与渲染")
struct TranslationPolicyTests {
    @Test("快捷键校验、修饰键显示顺序与 AppKit 位掩码映射")
    func shortcutConversionAndValidation() {
        #expect(TranslationShortcut.defaultScreenshot.enabled)
        #expect(TranslationShortcut.defaultScreenshot.keyCode == 0)
        #expect(
            TranslationShortcut.defaultScreenshot.carbonModifiers
                == (TranslationShortcut.optionBit | TranslationShortcut.shiftBit))
        #expect(TranslationShortcut.defaultScreenshot.label == "A")
        #expect(TranslationShortcut.defaultScreenshot.displayTitle == "⌥⇧A")

        let allModifiers = TranslationShortcut(
            enabled: true,
            keyCode: 40,
            carbonModifiers: TranslationShortcut.cmdBit
                | TranslationShortcut.shiftBit
                | TranslationShortcut.optionBit
                | TranslationShortcut.controlBit,
            label: "K")
        #expect(allModifiers.isValid)
        #expect(allModifiers.displayTitle == "⌃⌥⇧⌘K")

        let noModifier = TranslationShortcut(enabled: true, keyCode: 17, carbonModifiers: 0, label: "T")
        #expect(!noModifier.isValid)
        #expect(noModifier.displayTitle == "未设置")

        let blankLabel = TranslationShortcut(
            enabled: true, keyCode: 17, carbonModifiers: TranslationShortcut.cmdBit, label: "   \n")
        #expect(!blankLabel.isValid)
        #expect(blankLabel.displayTitle == "未设置")

        let disabled = TranslationShortcut(
            enabled: false, keyCode: 17, carbonModifiers: TranslationShortcut.optionBit, label: "T")
        #expect(disabled.isValid)
        #expect(disabled.displayTitle == "未设置")

        #expect(TranslationShortcut.from(keyCode: 17, appKitModifierFlagsRaw: 0, label: "T") == nil)
        #expect(TranslationShortcut.from(keyCode: 17, appKitModifierFlagsRaw: 1 << 20, label: "  ") == nil)

        let rawFlags: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        let converted = TranslationShortcut.from(keyCode: 16, appKitModifierFlagsRaw: rawFlags, label: " Y ")
        #expect(
            converted
                == TranslationShortcut(
                    enabled: true,
                    keyCode: 16,
                    carbonModifiers: TranslationShortcut.allowedModifierMask,
                    label: "Y"))
    }

    @Test("自动与指定目标语种解析避免源目标语言相同")
    func languageResolution() {
        #expect(
            TranslationTargetLanguage.auto.resolveLanguages(for: "你好世界", detectedLanguage: nil) == ("zh-Hans", "en"))
        #expect(
            TranslationTargetLanguage.auto.resolveLanguages(for: "Hello world", detectedLanguage: "en")
                == ("en", "zh-Hans"))
        #expect(
            TranslationTargetLanguage.simplifiedChinese.resolveLanguages(for: "中文说明", detectedLanguage: nil)
                == ("en", "zh-Hans"))
        #expect(
            TranslationTargetLanguage.english.resolveLanguages(for: "Hello", detectedLanguage: "en")
                == ("zh-Hans", "en"))
        #expect(
            TranslationTargetLanguage.japanese.resolveLanguages(for: "Automations", detectedLanguage: "en")
                == ("en", "ja"))
    }

    @Test("OpenAI 兼容接口地址规范化、拦截公网明文 HTTP 与预设配置")
    func openAIEndpointAndPresets() {
        let httpsBase = OpenAICompatibleConfig(baseURL: "https://api.openai.com/v1/", model: "gpt-4o-mini")
        #expect(httpsBase.resolvedEndpointURL()?.absoluteString == "https://api.openai.com/v1/chat/completions")

        let alreadyFull = OpenAICompatibleConfig(
            baseURL: "https://gateway.example.com/custom/chat/completions", model: "m")
        #expect(
            alreadyFull.resolvedEndpointURL()?.absoluteString == "https://gateway.example.com/custom/chat/completions")

        let rootOnly = OpenAICompatibleConfig(baseURL: "https://api.example.com", model: "m")
        #expect(rootOnly.resolvedEndpointURL()?.absoluteString == "https://api.example.com/v1/chat/completions")

        let localHTTP = OpenAICompatibleConfig(baseURL: "http://127.0.0.1:8080/v1", model: "local")
        #expect(localHTTP.resolvedEndpointURL()?.absoluteString == "http://127.0.0.1:8080/v1/chat/completions")

        let tailscaleHTTP = OpenAICompatibleConfig(baseURL: "http://100.64.1.2:3000", model: "local")
        #expect(tailscaleHTTP.resolvedEndpointURL()?.absoluteString == "http://100.64.1.2:3000/v1/chat/completions")

        let publicHTTP = OpenAICompatibleConfig(baseURL: "http://example.com/v1", model: "m")
        #expect(publicHTTP.resolvedEndpointURL() == nil)

        // 严格私网 / 回环校验：拒绝伪装域名与非私网前缀 IP
        let allowedHTTPURLs = [
            "http://localhost:11434/v1",
            "http://127.0.0.1:8080",
            "http://127.1.2.3:8080",
            "http://[::1]:11434/v1",
            "http://10.0.0.5:8000/v1",
            "http://172.16.0.1:8000/v1",
            "http://172.31.255.254:8000/v1",
            "http://192.168.1.20:8000/v1",
            "http://100.64.0.1:8000/v1",
            "http://100.127.255.254:8000/v1",
            "http://169.254.1.10:8000/v1",
            "http://[fd00::1]:8000/v1",
            "http://[fe80::1]:8000/v1",
        ]
        for raw in allowedHTTPURLs {
            let cfg = OpenAICompatibleConfig(baseURL: raw, model: "m")
            #expect(cfg.resolvedEndpointURL() != nil, "Expected allowed endpoint: \(raw)")
        }

        let rejectedHTTPURLs = [
            "http://172.8.1.1/v1",
            "http://172.32.0.1/v1",
            "http://100.1.1.1/v1",
            "http://100.128.0.1/v1",
            "http://10.example.com/v1",
            "http://127.0.0.1.nip.io/v1",
            "http://192.168.example.com/v1",
        ]
        for raw in rejectedHTTPURLs {
            let cfg = OpenAICompatibleConfig(baseURL: raw, model: "m")
            #expect(cfg.resolvedEndpointURL() == nil, "Expected rejected endpoint: \(raw)")
        }

        // credentialScope 与 allowsEmptyAPIKey
        #expect(
            OpenAICompatibleConfig(baseURL: "https://API.OpenAI.COM:443/v1", model: "gpt-4o-mini").credentialScope
                == "https://api.openai.com")
        #expect(
            OpenAICompatibleConfig(baseURL: "https://api.deepseek.com", model: "deepseek-chat").credentialScope
                == "https://api.deepseek.com")
        #expect(
            OpenAICompatibleConfig(baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5").credentialScope
                == "http://127.0.0.1:11434")
        #expect(OpenAIProviderPreset.ollama.config.allowsEmptyAPIKey)
        #expect(OpenAICompatibleConfig(baseURL: "http://localhost:8080/v1", model: "m").allowsEmptyAPIKey)
        #expect(OpenAICompatibleConfig(baseURL: "http://[::1]:11434/v1", model: "m").allowsEmptyAPIKey)
        #expect(!OpenAICompatibleConfig(baseURL: "http://192.168.1.10:11434/v1", model: "m").allowsEmptyAPIKey)
        #expect(!OpenAIProviderPreset.openAI.config.allowsEmptyAPIKey)
        #expect(!OpenAIProviderPreset.deepseek.config.allowsEmptyAPIKey)

        #expect(OpenAIProviderPreset.allCases == [.deepseek, .openAI, .ollama])
        #expect(OpenAIProviderPreset.deepseek.title == "DeepSeek")
        #expect(OpenAIProviderPreset.deepseek.config.baseURL == "https://api.deepseek.com")
        #expect(OpenAIProviderPreset.deepseek.config.model == "deepseek-chat")
        #expect(
            OpenAIProviderPreset.deepseek.config.resolvedEndpointURL()?.absoluteString
                == "https://api.deepseek.com/v1/chat/completions")

        #expect(OpenAIProviderPreset.openAI.title == "OpenAI")
        #expect(OpenAIProviderPreset.openAI.config.baseURL == "https://api.openai.com/v1")
        #expect(OpenAIProviderPreset.openAI.config.model == "gpt-4o-mini")

        #expect(OpenAIProviderPreset.ollama.title == "Ollama")
        #expect(OpenAIProviderPreset.ollama.config.baseURL == "http://127.0.0.1:11434/v1")
        #expect(OpenAIProviderPreset.ollama.config.model == "qwen2.5")
        #expect(
            OpenAIProviderPreset.ollama.config.resolvedEndpointURL()?.absoluteString
                == "http://127.0.0.1:11434/v1/chat/completions")
    }

    @Test("兼容旧版废弃键的翻译配置与完整新字段往返")
    func preferencesDecodingAndLegacyCompatibility() throws {
        let decodedEmpty = try JSONDecoder().decode(TranslationPreferences.self, from: Data("{}".utf8))
        #expect(decodedEmpty == TranslationPreferences())

        let legacyJSON = #"""
            {
                "defaultMode": "dictionary",
                "clipboardShortcut": {"enabled": true, "keyCode": 16, "carbonModifiers": 2560, "label": "Y"},
                "copyOCRToClipboard": true,
                "mergeOCRLineBreaks": false
            }
            """#
        let decodedLegacy = try JSONDecoder().decode(TranslationPreferences.self, from: Data(legacyJSON.utf8))
        #expect(decodedLegacy.screenshotShortcut == .defaultScreenshot)
        #expect(decodedLegacy.engine == .apple)
        #expect(decodedLegacy.targetLanguage == .auto)
        #expect(!decodedLegacy.mergeOCRLineBreaks)

        var custom = TranslationPreferences()
        custom.screenshotShortcut = TranslationShortcut(
            enabled: true, keyCode: 3, carbonModifiers: TranslationShortcut.cmdBit, label: "F")
        custom.engine = .openAICompatible
        custom.targetLanguage = .japanese
        custom.mergeOCRLineBreaks = false
        custom.apiConfig = OpenAIProviderPreset.deepseek.config

        let data = try JSONEncoder().encode(custom)
        let roundtripped = try JSONDecoder().decode(TranslationPreferences.self, from: data)
        #expect(roundtripped == custom)
    }

    @Test("标注工具、调色板、线宽与标注模型属性")
    func annotationModels() throws {
        #expect(ScreenshotTool.allCases == [.none, .rectangle, .arrow, .pen])

        #expect(AnnotationColor.applePalette.count == 6)
        #expect(AnnotationColor.defaultColor == AnnotationColor.applePalette[0])
        #expect(AnnotationColor.defaultColor.id == "coralRed")
        #expect(AnnotationColor.defaultColor.name == "珊瑚红")

        let encodedColor = try JSONEncoder().encode(AnnotationColor.applePalette[3])
        let decodedColor = try JSONDecoder().decode(AnnotationColor.self, from: encodedColor)
        #expect(decodedColor == AnnotationColor.applePalette[3])

        #expect(AnnotationStrokeSize.thin.lineWidth == 2)
        #expect(AnnotationStrokeSize.medium.lineWidth == 4)
        #expect(AnnotationStrokeSize.thick.lineWidth == 7)
        #expect(AnnotationStrokeSize.thin.indicatorDiameter == 4)
        #expect(AnnotationStrokeSize.medium.indicatorDiameter == 7)
        #expect(AnnotationStrokeSize.thick.indicatorDiameter == 10)

        let annotation = ScreenshotAnnotation(
            kind: .rectangle(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)),
            color: .defaultColor,
            size: .medium)
        #expect(annotation.color == AnnotationColor.defaultColor)
        #expect(annotation.size == .medium)
    }

    @Test("选区命中测试、缩放边界限制、键盘微调与窗口吸附")
    func selectionGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 100, y: 200, width: 300, height: 150)

        #expect(ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 100, y: 350), selection: selection) == .topLeft)
        #expect(ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 250, y: 350), selection: selection) == .top)
        #expect(ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 400, y: 350), selection: selection) == .topRight)
        #expect(ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 400, y: 275), selection: selection) == .right)
        #expect(
            ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 400, y: 200), selection: selection) == .bottomRight)
        #expect(ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 250, y: 200), selection: selection) == .bottom)
        #expect(
            ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 100, y: 200), selection: selection) == .bottomLeft)
        #expect(ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 100, y: 275), selection: selection) == .left)
        #expect(ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 250, y: 275), selection: selection) == .inside)
        #expect(ScreenshotSelectionGeometry.hitTest(point: CGPoint(x: 20, y: 20), selection: selection) == nil)

        let resizedTopLeft = ScreenshotSelectionGeometry.resize(
            selection: selection,
            handle: .topLeft,
            delta: CGSize(width: -150, height: 600),
            within: bounds)
        #expect(resizedTopLeft == CGRect(x: 0, y: 200, width: 400, height: 600))

        let clampedMin = ScreenshotSelectionGeometry.resize(
            selection: selection,
            handle: .bottomRight,
            delta: CGSize(width: -500, height: 500),
            within: bounds,
            minSize: 12)
        #expect(clampedMin.width == 12)
        #expect(clampedMin.height == 12)
        #expect(clampedMin.minX == 100)
        #expect(clampedMin.maxY == 350)

        let moved = ScreenshotSelectionGeometry.resize(
            selection: selection,
            handle: .inside,
            delta: CGSize(width: 900, height: -300),
            within: bounds)
        #expect(moved == CGRect(x: 700, y: 0, width: 300, height: 150))

        let nudged = ScreenshotSelectionGeometry.nudge(selection: selection, dx: -150, dy: 10, within: bounds)
        #expect(nudged == CGRect(x: 0, y: 210, width: 300, height: 150))

        let frontWindow = CGRect(x: 200, y: 200, width: 300, height: 200)
        let backWindow = CGRect(x: 100, y: 100, width: 700, height: 600)
        let clippedEdgeWindow = CGRect(x: -50, y: 20, width: 200, height: 120)
        let tinySliver = CGRect(x: 990, y: 20, width: 40, height: 40)

        #expect(
            ScreenshotSelectionGeometry.snappedWindowRect(
                at: CGPoint(x: 250, y: 250),
                windows: [frontWindow, backWindow],
                within: bounds) == frontWindow)
        #expect(
            ScreenshotSelectionGeometry.snappedWindowRect(
                at: CGPoint(x: 120, y: 120),
                windows: [frontWindow, backWindow],
                within: bounds) == backWindow)
        #expect(
            ScreenshotSelectionGeometry.snappedWindowRect(
                at: CGPoint(x: 50, y: 50),
                windows: [clippedEdgeWindow],
                within: bounds) == CGRect(x: 0, y: 20, width: 150, height: 120))
        #expect(
            ScreenshotSelectionGeometry.snappedWindowRect(
                at: CGPoint(x: 995, y: 30),
                windows: [tinySliver],
                within: bounds) == nil)
    }

    @Test("合并换行整理断行断词及合并同行相邻 OCR 区块")
    func normalizeAndMergeRegions() {
        #expect(TranslationTextNormalizer.normalize("   \r\n\t  \n ", mergeLineBreaks: true).isEmpty)
        #expect(
            TranslationTextNormalizer.normalize("This algo-\nrithm\nworks.", mergeLineBreaks: true)
                == "This algorithm works.")
        #expect(TranslationTextNormalizer.normalize("你好\n世界\nVorsmate。", mergeLineBreaks: true) == "你好世界Vorsmate。")
        #expect(
            TranslationTextNormalizer.normalize("  Line one  \t\r\n\n\nLine two  ", mergeLineBreaks: false)
                == "Line one\n\nLine two")

        let r1 = RecognizedTextRegion(text: "Hello", normalizedBox: CGRect(x: 0.1, y: 0.7, width: 0.12, height: 0.08))
        let r2 = RecognizedTextRegion(
            text: "world", normalizedBox: CGRect(x: 0.24, y: 0.705, width: 0.12, height: 0.08))
        let r3 = RecognizedTextRegion(
            text: "Next line", normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.08))
        let r4 = RecognizedTextRegion(
            text: "Far column", normalizedBox: CGRect(x: 0.72, y: 0.7, width: 0.2, height: 0.08))

        let merged = TranslationTextNormalizer.mergeHorizontalRegions([r4, r2, r3, r1])
        #expect(merged.count == 3)
        #expect(merged[0].text == "Hello world")
        #expect(merged[1].text == "Far column")
        #expect(merged[2].text == "Next line")

        // 宽横幅（2000x100）：水平间距 160px > 1.2 * 50px，不应误合并
        let wideLeft = RecognizedTextRegion(
            text: "Left", normalizedBox: CGRect(x: 0.10, y: 0.25, width: 0.10, height: 0.50))
        let wideRight = RecognizedTextRegion(
            text: "Right", normalizedBox: CGRect(x: 0.28, y: 0.25, width: 0.10, height: 0.50))
        let wideMerged = TranslationTextNormalizer.mergeHorizontalRegions(
            [wideRight, wideLeft],
            imageSize: CGSize(width: 2000, height: 100))
        #expect(wideMerged.count == 2)

        // 窄竖条（200x1000）：水平间距 16px <= 1.2 * 40px，应合并
        let tallLeft = RecognizedTextRegion(
            text: "Hello", normalizedBox: CGRect(x: 0.10, y: 0.50, width: 0.30, height: 0.04))
        let tallRight = RecognizedTextRegion(
            text: "world", normalizedBox: CGRect(x: 0.48, y: 0.50, width: 0.30, height: 0.04))
        let tallMerged = TranslationTextNormalizer.mergeHorizontalRegions(
            [tallRight, tallLeft],
            imageSize: CGSize(width: 200, height: 1000))
        #expect(tallMerged.count == 1)
        #expect(tallMerged[0].text == "Hello world")
    }

    @Test("原场景裁切、局部译文回填、矢量标注与合成渲染")
    func sceneImageCropAnnotateAndComposite() throws {
        let original = try Self.makeSolidImage(width: 300, height: 160, r: 0.95, g: 0.95, b: 0.95)
        let translated = try Self.makeSolidImage(width: 300, height: 160, r: 0.15, g: 0.25, b: 0.45)

        let cropped = try #require(
            SceneImageRenderer.crop(
                image: original,
                screenFrame: CGRect(x: 0, y: 0, width: 150, height: 80),
                selectionScreenRect: CGRect(x: 10, y: 10, width: 100, height: 60)))
        #expect(cropped.width == 200)
        #expect(cropped.height == 120)
        #expect(cropped.bytesPerRow == 200 * 4)
        #expect(cropped.dataProvider !== original.dataProvider)

        let regions = [
            TranslatedTextRegion(
                original: "Automations",
                translated: "自动化工作流",
                normalizedBox: CGRect(x: 0.12, y: 0.35, width: 0.45, height: 0.22))
        ]
        let rendered = SceneImageRenderer.render(original: original, regions: regions)
        #expect(rendered.width == original.width)
        #expect(rendered.height == original.height)

        let annotations = [
            ScreenshotAnnotation(
                kind: .rectangle(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)),
                color: .defaultColor,
                size: .medium),
            ScreenshotAnnotation(
                kind: .arrow(start: CGPoint(x: 0.45, y: 0.2), end: CGPoint(x: 0.75, y: 0.65)),
                color: AnnotationColor.applePalette[3],
                size: .thick),
            ScreenshotAnnotation(
                kind: .pen(points: [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.5, y: 0.85), CGPoint(x: 0.8, y: 0.82)]),
                color: AnnotationColor.applePalette[2],
                size: .thin),
        ]
        let annotated = SceneImageRenderer.renderAnnotations(base: original, annotations: annotations, scaleFactor: 2)
        #expect(annotated.width == original.width)
        #expect(annotated.height == original.height)
        #expect(try Self.pixelBytes(annotated) != Self.pixelBytes(original))

        let compositeOriginal = SceneImageRenderer.renderComposite(
            original: original,
            translated: translated,
            showTranslation: false,
            annotations: annotations,
            scaleFactor: 2)
        let compositeTranslated = SceneImageRenderer.renderComposite(
            original: original,
            translated: translated,
            showTranslation: true,
            annotations: annotations,
            scaleFactor: 2)
        let compositeFallback = SceneImageRenderer.renderComposite(
            original: original,
            translated: nil,
            showTranslation: true,
            annotations: [],
            scaleFactor: 2)
        #expect(compositeOriginal.width == original.width)
        #expect(compositeTranslated.width == original.width)
        #expect(try Self.pixelBytes(compositeOriginal) != Self.pixelBytes(compositeTranslated))
        #expect(try Self.pixelBytes(compositeFallback) == Self.pixelBytes(original))
    }

    @Test("预览驱动包含示例窗口列表并支持无界面保存计数")
    @MainActor
    func previewDriverWindowRectsAndSaveCount() async throws {
        let driver = PreviewTranslationCaptureDriver()
        let snapshots = try await driver.captureScreens(excludingWindowNumbers: [])
        #expect(snapshots.count == 1)
        #expect(!snapshots[0].windowRects.isEmpty)

        let result = driver.saveImageToFile(snapshots[0].image, suggestedName: "vorsmate-test")
        if case .saved(let url) = result {
            #expect(url.lastPathComponent == "vorsmate-test.png")
        } else {
            Issue.record("Expected .saved result")
        }
        #expect(driver.savedImagesCount == 1)
    }

    @Test("OpenAI 兼容客户端按作用域隔离密钥、支持本地免密钥并严格校验批量条数")
    func openAIClientAndScopedKeyStore() async throws {
        #expect(
            TranslationServiceError.missingAPIKey.errorDescription
                == "尚未配置模型接口密钥，请在菜单栏「截图」展开栏填写并保存密钥。")

        let openAIScope = try #require(OpenAIProviderPreset.openAI.config.credentialScope)
        let deepseekScope = try #require(OpenAIProviderPreset.deepseek.config.credentialScope)
        let keyStore = InMemoryTranslationAPIKeyStore()
        #expect(!keyStore.hasAPIKey(forScope: openAIScope))
        try keyStore.saveAPIKey("  sk-test-123  ", forScope: openAIScope)
        #expect(keyStore.hasAPIKey(forScope: openAIScope))
        #expect(!keyStore.hasAPIKey(forScope: deepseekScope))
        #expect(try keyStore.loadAPIKey(forScope: openAIScope) == "sk-test-123")
        #expect(try keyStore.loadAPIKey(forScope: deepseekScope) == nil)

        let mockTransport = MockOpenAITransport { request in
            let body = try #require(request.httpBody)
            let rawText = String(decoding: body, as: UTF8.self)
            let content =
                rawText.contains("items")
                ? "```json\n{\"translations\":[\"+ 新对话\",\"自动化\"]}\n```"
                : "你好，世界"
            let json = """
                {"choices":[{"message":{"content":\(Self.jsonString(content))}}]}
                """
            let response = HTTPURLResponse(
                url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let translator = OpenAICompatibleTranslator(transport: mockTransport)
        let cfg = OpenAICompatibleConfig(baseURL: "https://api.example.com/v1", model: "gpt-4o-mini")

        let single = try await translator.translateBatch(
            ["Hello, world"], source: "en", target: "zh-Hans", config: cfg, apiKey: "sk-test-123")
        #expect(single == ["你好，世界"])

        let batch = try await translator.translateBatch(
            ["+ New Conversation", "Automations"], source: "en", target: "zh-Hans", config: cfg, apiKey: "sk-test-123")
        #expect(batch == ["+ 新对话", "自动化"])

        await #expect(throws: TranslationServiceError.missingAPIKey) {
            _ = try await translator.translateBatch(["Hi"], source: "en", target: "zh-Hans", config: cfg, apiKey: "  ")
        }

        // Ollama 回环地址免密钥且不带 Authorization 头
        let ollamaTransport = MockOpenAITransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let json = #"{"choices":[{"message":{"content":"本地译文"}}]}"#
            let response = HTTPURLResponse(
                url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let ollamaTranslator = OpenAICompatibleTranslator(transport: ollamaTransport)
        let ollamaOut = try await ollamaTranslator.translateBatch(
            ["Local"], source: "en", target: "zh-Hans", config: OpenAIProviderPreset.ollama.config, apiKey: "")
        #expect(ollamaOut == ["本地译文"])

        // 非回环内网仍需密钥
        let lanCfg = OpenAICompatibleConfig(baseURL: "http://192.168.1.10:11434/v1", model: "qwen2.5")
        await #expect(throws: TranslationServiceError.missingAPIKey) {
            _ = try await ollamaTranslator.translateBatch(
                ["LAN"], source: "en", target: "zh-Hans", config: lanCfg, apiKey: "")
        }

        // 批量返回数量不匹配或非 JSON 必须严格拒绝
        let mismatchTransport = MockOpenAITransport { request in
            let json = #"{"choices":[{"message":{"content":"{\"translations\":[\"只有一条\"]}"}}]}"#
            let response = HTTPURLResponse(
                url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let mismatchTranslator = OpenAICompatibleTranslator(transport: mismatchTransport)
        await #expect(throws: TranslationServiceError.invalidResponse("批量译文数量不匹配（预期 2 条，实际返回 1 条）")) {
            _ = try await mismatchTranslator.translateBatch(
                ["One", "Two"], source: "en", target: "zh-Hans", config: cfg, apiKey: "sk-test-123")
        }

        let plainTextTransport = MockOpenAITransport { request in
            let json = #"{"choices":[{"message":{"content":"第一行\n第二行"}}]}"#
            let response = HTTPURLResponse(
                url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let plainTextTranslator = OpenAICompatibleTranslator(transport: plainTextTransport)
        await #expect(throws: TranslationServiceError.invalidResponse("批量译文格式解析失败")) {
            _ = try await plainTextTranslator.translateBatch(
                ["One", "Two"], source: "en", target: "zh-Hans", config: cfg, apiKey: "sk-test-123")
        }

        // 取消错误保留 CancellationError 语义
        let cancelledTransport = MockOpenAITransport { _ in
            throw URLError(.cancelled)
        }
        let cancelledTranslator = OpenAICompatibleTranslator(transport: cancelledTransport)
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledTranslator.translateBatch(
                ["Hi"], source: "en", target: "zh-Hans", config: cfg, apiKey: "sk-test-123")
        }

        try keyStore.deleteAPIKey(forScope: openAIScope)
        #expect(!keyStore.hasAPIKey(forScope: openAIScope))
    }

    @Test("URLSession 传输层拦截跨源与不安全 HTTP 重定向")
    func urlSessionTransportBlocksUnsafeAndCrossOriginRedirects() async throws {
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let transport = URLSessionOpenAITransport(timeoutInterval: 3)

        let unsafeURL = URL(string: "http://127.0.0.1:\(server.port)/unsafe")!
        await #expect(throws: TranslationServiceError.invalidEndpoint) {
            _ = try await transport.send(URLRequest(url: unsafeURL))
        }

        let crossOriginURL = URL(string: "http://127.0.0.1:\(server.port)/cross")!
        await #expect(throws: TranslationServiceError.invalidResponse("已拦截不安全或跨源重定向")) {
            _ = try await transport.send(URLRequest(url: crossOriginURL))
        }

        let sameOriginURL = URL(string: "http://127.0.0.1:\(server.port)/same")!
        let (data, http) = try await transport.send(URLRequest(url: sameOriginURL))
        #expect(http.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func makeSolidImage(
        width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(ctx.makeImage())
    }

    private static func pixelBytes(_ image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let ctx = try #require(
            buffer.withUnsafeMutableBytes { rawPtr -> CGContext? in
                CGContext(
                    data: rawPtr.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            })
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(buffer)
    }
}

private final class MockOpenAITransport: OpenAITranslationTransport, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try handler(request)
    }
}

private final class LoopbackRedirectServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EIO)
        }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(fd, saPtr, &len)
            }
        }
        self.port = UInt16(bigEndian: assigned.sin_port)
        self.listenFD = fd

        DispatchQueue.global(qos: .userInitiated).async { [listenFD = fd] in
            while true {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        accept(listenFD, saPtr, &clientLen)
                    }
                }
                if clientFD < 0 { break }
                Self.handleClient(clientFD)
            }
        }
    }

    func stop() {
        close(listenFD)
    }

    private static func handleClient(_ clientFD: Int32) {
        defer { close(clientFD) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let readCount = recv(clientFD, &buf, buf.count, 0)
        guard readCount > 0 else { return }
        let requestText = String(decoding: buf.prefix(readCount), as: UTF8.self)
        let firstLine = requestText.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let path = firstLine.split(separator: " ").dropFirst().first ?? "/"

        let response: String
        switch path {
        case "/unsafe":
            response =
                "HTTP/1.1 302 Found\r\nLocation: http://evil.example.com/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        case "/cross":
            response =
                "HTTP/1.1 302 Found\r\nLocation: https://other.example.com/v1/chat/completions\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        case "/same":
            response = "HTTP/1.1 302 Found\r\nLocation: /v2/ok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        default:
            response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        }
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBytes { rawPtr in
            send(clientFD, rawPtr.baseAddress, bytes.count, 0)
        }
    }
}
