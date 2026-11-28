// [INPUT]: 截图选区、矢量标注与原场景翻译图层。
// [OUTPUT]: 可比较的截图会话快照与缓存的合成图像。
// [POS]: 截图面板和叠层共享的值类型，不调度 OCR、热键或窗口。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
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
