// [INPUT]: AppKit 剪贴板/保存面板、ScreenCaptureKit 屏幕快照、CGWindowList 窗口列表、Vision 文字识别与 VorsmateCore 策略。
// [OUTPUT]: 多屏桌面快照与窗口矩形采集、带归一化坐标的文字识别、剪贴板读写、文件保存与离线预览替身。
// [POS]: VorsmateSystem 截图、窗口探测与文字识别边界；不加载网页、不保存历史截图。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision
import VorsmateCore

public struct CapturedScreenSnapshot: Sendable {
    public let displayID: CGDirectDisplayID
    public let screenFrame: CGRect
    public let scaleFactor: CGFloat
    public let image: CGImage
    public let windowRects: [CGRect]

    public init(
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        scaleFactor: CGFloat,
        image: CGImage,
        windowRects: [CGRect] = []
    ) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.scaleFactor = scaleFactor
        self.image = image
        self.windowRects = windowRects
    }
}

public enum TranslationCaptureError: LocalizedError, Equatable, Sendable {
    case cancelled
    case permissionDenied
    case noTextDetected
    case captureFailed(String)
    case ocrFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return nil
        case .permissionDenied:
            return "缺少录屏权限，请在「系统设置 → 隐私与安全性 → 录屏与系统录音」中允许当前 Vorsmate 后重启应用。"
        case .noTextDetected:
            return "未在截图中识别到文字。"
        case .captureFailed(let detail):
            return "截图失败：\(detail)"
        case .ocrFailed(let detail):
            return "文字识别失败：\(detail)"
        }
    }
}

public enum ImageSaveResult: Equatable, Sendable {
    case saved(URL)
    case cancelled
    case failed(String)
}

@MainActor
public protocol TranslationCaptureDriver: AnyObject {
    func hasScreenCapturePermission() -> Bool
    @discardableResult
    func requestScreenCapturePermission() -> Bool
    func openScreenCaptureSettings()
    func captureScreens(excludingWindowNumbers: [Int]) async throws -> [CapturedScreenSnapshot]
    func recognizeRegions(
        in image: CGImage, mergeLineBreaks: Bool
    ) async throws -> (regions: [RecognizedTextRegion], combinedText: String)
    func readClipboardText() -> String?
    func writeClipboardText(_ text: String)
    func writeClipboardImage(_ image: CGImage)
    func saveImageToFile(_ image: CGImage, suggestedName: String) -> ImageSaveResult
}

@MainActor
public final class SystemTranslationCaptureDriver: TranslationCaptureDriver {
    public init() {}

    public func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    public func captureScreens(excludingWindowNumbers: [Int]) async throws -> [CapturedScreenSnapshot] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            throw TranslationCaptureError.captureFailed("未找到可用显示器。")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !hasScreenCapturePermission() {
                _ = requestScreenCapturePermission()
                throw TranslationCaptureError.permissionDenied
            }
            let lower = error.localizedDescription.lowercased()
            if lower.contains("permission") || lower.contains("denied") || lower.contains("not authorized")
                || lower.contains("tcc")
            {
                _ = requestScreenCapturePermission()
                throw TranslationCaptureError.permissionDenied
            }
            throw TranslationCaptureError.captureFailed(error.localizedDescription)
        }

        let excludedIDs = Set(excludingWindowNumbers.map { CGWindowID($0) })
        let excludedWindows = content.windows.filter { excludedIDs.contains($0.windowID) }

        let excludedSet = Set(excludingWindowNumbers)
        let primaryHeight = screens.first?.frame.height ?? 0
        let allWindowRects = Self.onScreenAppKitWindowRects(
            excludingWindowNumbers: excludedSet,
            primaryScreenHeight: primaryHeight)

        var displayByID: [CGDirectDisplayID: SCDisplay] = [:]
        for display in content.displays {
            displayByID[display.displayID] = display
        }

        var snapshots: [CapturedScreenSnapshot] = []
        for screen in screens {
            try Task.checkCancellation()
            guard let displayID = Self.displayID(for: screen), let display = displayByID[displayID] else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            let scale = max(1, screen.backingScaleFactor)
            config.width = max(1, Int((screen.frame.width * scale).rounded()))
            config.height = max(1, Int((screen.frame.height * scale).rounded()))
            config.showsCursor = false
            config.capturesAudio = false

            let screenWindowRects = allWindowRects.compactMap { rect -> CGRect? in
                let clipped = rect.intersection(screen.frame)
                guard !clipped.isNull, clipped.width >= 24, clipped.height >= 24 else { return nil }
                return clipped
            }

            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                snapshots.append(
                    CapturedScreenSnapshot(
                        displayID: displayID,
                        screenFrame: screen.frame,
                        scaleFactor: scale,
                        image: image,
                        windowRects: screenWindowRects))
            } catch {
                if !hasScreenCapturePermission() {
                    _ = requestScreenCapturePermission()
                    throw TranslationCaptureError.permissionDenied
                }
                throw TranslationCaptureError.captureFailed(error.localizedDescription)
            }
        }

        guard !snapshots.isEmpty else {
            throw TranslationCaptureError.captureFailed("未能捕获当前屏幕画面。")
        }
        return snapshots
    }

    public func recognizeRegions(
        in image: CGImage, mergeLineBreaks: Bool
    ) async throws -> (regions: [RecognizedTextRegion], combinedText: String) {
        let rawRegions = try await Task.detached(priority: .userInitiated) {
            try Self.recognizeTextRegions(in: image)
        }.value

        let merged = TranslationTextNormalizer.mergeHorizontalRegions(
            rawRegions,
            imageSize: CGSize(width: image.width, height: image.height))
        let joined = merged.map(\.text).joined(separator: "\n")
        let combined = TranslationTextNormalizer.normalize(joined, mergeLineBreaks: mergeLineBreaks)
        guard !merged.isEmpty, !combined.isEmpty else {
            throw TranslationCaptureError.noTextDetected
        }
        return (merged, combined)
    }

    public func readClipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    public func writeClipboardText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func writeClipboardImage(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    public func saveImageToFile(_ image: CGImage, suggestedName: String) -> ImageSaveResult {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return .failed("无法编码截图为 PNG 格式。")
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }
        do {
            try pngData.write(to: url, options: .atomic)
            return .saved(url)
        } catch {
            return .failed("保存图片失败：\(error.localizedDescription)")
        }
    }

    private static func onScreenAppKitWindowRects(
        excludingWindowNumbers: Set<Int>,
        primaryScreenHeight: CGFloat
    ) -> [CGRect] {
        guard
            let rawList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        var rects: [CGRect] = []
        for info in rawList {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.01 else { continue }
            guard let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                !excludingWindowNumbers.contains(windowNumber)
            else {
                continue
            }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let quartzRect = CGRect(dictionaryRepresentation: boundsDict),
                quartzRect.width >= 40,
                quartzRect.height >= 30
            else {
                continue
            }

            let appKitRect = CGRect(
                x: quartzRect.origin.x,
                y: primaryScreenHeight - quartzRect.origin.y - quartzRect.size.height,
                width: quartzRect.size.width,
                height: quartzRect.size.height)
            rects.append(appKitRect)
        }
        return rects
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private nonisolated static func recognizeTextRegions(in cgImage: CGImage) throws -> [RecognizedTextRegion] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw TranslationCaptureError.ocrFailed(error.localizedDescription)
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return RecognizedTextRegion(text: text, normalizedBox: observation.boundingBox)
        }
    }
}

@MainActor
public final class PreviewTranslationCaptureDriver: TranslationCaptureDriver {
    private var clipboard: String? = "Vorsmate supports offline macOS translation."
    public private(set) var writtenImagesCount = 0
    public private(set) var savedImagesCount = 0

    public init() {}

    public func hasScreenCapturePermission() -> Bool { true }

    @discardableResult
    public func requestScreenCapturePermission() -> Bool { true }

    public func openScreenCaptureSettings() {}

    public func captureScreens(excludingWindowNumbers: [Int]) async throws -> [CapturedScreenSnapshot] {
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let sampleImage = Self.makeSampleImage(width: 720, height: 440)
        let sampleWindowRect = CGRect(
            x: screenFrame.minX + 120,
            y: screenFrame.minY + 120,
            width: min(640, max(200, screenFrame.width - 240)),
            height: min(420, max(160, screenFrame.height - 240)))
        return [
            CapturedScreenSnapshot(
                displayID: CGMainDisplayID(),
                screenFrame: screenFrame,
                scaleFactor: 2,
                image: sampleImage,
                windowRects: [sampleWindowRect])
        ]
    }

    public func recognizeRegions(
        in image: CGImage, mergeLineBreaks: Bool
    ) async throws -> (regions: [RecognizedTextRegion], combinedText: String) {
        let sampleRegions = [
            RecognizedTextRegion(
                text: "+ New Conversation",
                normalizedBox: CGRect(x: 0.08, y: 0.68, width: 0.56, height: 0.11)),
            RecognizedTextRegion(
                text: "Automations",
                normalizedBox: CGRect(x: 0.08, y: 0.47, width: 0.36, height: 0.10)),
            RecognizedTextRegion(
                text: "Customizations",
                normalizedBox: CGRect(x: 0.08, y: 0.27, width: 0.44, height: 0.10)),
        ]
        let combined = TranslationTextNormalizer.normalize(
            sampleRegions.map(\.text).joined(separator: "\n"),
            mergeLineBreaks: mergeLineBreaks)
        return (sampleRegions, combined)
    }

    public func readClipboardText() -> String? {
        clipboard
    }

    public func writeClipboardText(_ text: String) {
        clipboard = text
    }

    public func writeClipboardImage(_ image: CGImage) {
        writtenImagesCount += 1
    }

    public func saveImageToFile(_ image: CGImage, suggestedName: String) -> ImageSaveResult {
        savedImagesCount += 1
        let fileName = suggestedName.hasSuffix(".png") ? suggestedName : "\(suggestedName).png"
        return .saved(FileManager.default.temporaryDirectory.appending(path: fileName))
    }

    public static func makeSampleImage(width: Int = 720, height: Int = 440) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo)
        else {
            fatalError("Unable to create preview CGContext")
        }

        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let pillRect = CGRect(x: 42, y: CGFloat(height) * 0.64, width: CGFloat(width) * 0.72, height: 68)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 0.88, green: 0.88, blue: 0.86, alpha: 1))
        ctx.setLineWidth(2)
        ctx.addPath(pillPath)
        ctx.strokePath()

        let entries: [(String, CGPoint)] = [
            ("+ New Conversation", CGPoint(x: 58, y: CGFloat(height) * 0.68 + 10)),
            ("Automations", CGPoint(x: 58, y: CGFloat(height) * 0.47 + 8)),
            ("Customizations", CGPoint(x: 58, y: CGFloat(height) * 0.27 + 8)),
        ]
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 26, nil)
        let textColor = CGColor(red: 0.14, green: 0.14, blue: 0.13, alpha: 1)
        for (text, origin) in entries {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            ctx.textPosition = origin
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }
}
