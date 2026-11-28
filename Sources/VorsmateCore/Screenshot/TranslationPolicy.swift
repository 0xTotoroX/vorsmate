// [INPUT]: CoreGraphics 几何、Foundation 与截图翻译配置需求。
// [OUTPUT]: 截图快捷键、引擎与目标语种策略、OpenAI 兼容接口预设与校验、文本行整理与识别区块合并。
// [POS]: 截图与翻译纯逻辑策略层；不依赖 AppKit、ScreenCaptureKit 或 Translation 框架。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
import Darwin
import Foundation

public struct TranslationShortcut: Codable, Equatable, Sendable {
    public static let cmdBit: UInt32 = 0x0100
    public static let shiftBit: UInt32 = 0x0200
    public static let optionBit: UInt32 = 0x0800
    public static let controlBit: UInt32 = 0x1000
    public static let allowedModifierMask: UInt32 = cmdBit | shiftBit | optionBit | controlBit

    public var enabled: Bool
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var label: String

    public init(enabled: Bool, keyCode: UInt32, carbonModifiers: UInt32, label: String) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = label
    }

    public static let defaultScreenshot = Self(
        enabled: true, keyCode: 0, carbonModifiers: optionBit | shiftBit, label: "A")

    public var isValid: Bool {
        let hasModifier = (carbonModifiers & Self.allowedModifierMask) != 0
        return hasModifier && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var displayTitle: String {
        guard enabled, isValid else { return "未设置" }
        var prefix = ""
        if carbonModifiers & Self.controlBit != 0 { prefix += "⌃" }
        if carbonModifiers & Self.optionBit != 0 { prefix += "⌥" }
        if carbonModifiers & Self.shiftBit != 0 { prefix += "⇧" }
        if carbonModifiers & Self.cmdBit != 0 { prefix += "⌘" }
        return prefix + label
    }

    public static func from(keyCode: UInt16, appKitModifierFlagsRaw: UInt, label: String) -> Self? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if appKitModifierFlagsRaw & (1 << 18) != 0 { modifiers |= controlBit }
        if appKitModifierFlagsRaw & (1 << 19) != 0 { modifiers |= optionBit }
        if appKitModifierFlagsRaw & (1 << 17) != 0 { modifiers |= shiftBit }
        if appKitModifierFlagsRaw & (1 << 20) != 0 { modifiers |= cmdBit }
        guard modifiers != 0 else { return nil }
        return Self(enabled: true, keyCode: UInt32(keyCode), carbonModifiers: modifiers, label: trimmed)
    }
}

public enum TranslationEngine: String, Codable, Equatable, CaseIterable, Sendable, Identifiable {
    case apple
    case openAICompatible

    public var id: Self { self }

    public var title: String {
        switch self {
        case .apple: "系统离线翻译"
        case .openAICompatible: "自定义模型接口"
        }
    }

    public var shortTitle: String {
        switch self {
        case .apple: "系统离线"
        case .openAICompatible: "模型接口"
        }
    }
}

public enum TranslationTargetLanguage: String, Codable, Equatable, CaseIterable, Sendable, Identifiable {
    case auto
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .auto: "自动（中英互译）"
        case .simplifiedChinese: "简体中文"
        case .english: "英语"
        case .japanese: "日语"
        }
    }

    public var shortTitle: String {
        switch self {
        case .auto: "自动"
        case .simplifiedChinese: "简中"
        case .english: "英语"
        case .japanese: "日语"
        }
    }

    public func resolveLanguages(for text: String, detectedLanguage: String?) -> (source: String, target: String) {
        let source = Self.normalizedSourceLanguage(for: text, detectedLanguage: detectedLanguage)
        switch self {
        case .auto:
            let target = source.hasPrefix("zh") ? "en" : "zh-Hans"
            return (source: source, target: target)
        case .simplifiedChinese, .english, .japanese:
            let target = rawValue
            if source == target {
                return (source: target == "zh-Hans" ? "en" : "zh-Hans", target: target)
            }
            return (source: source, target: target)
        }
    }

    private static func normalizedSourceLanguage(for text: String, detectedLanguage: String?) -> String {
        if TranslationTextNormalizer.containsMostlyCJKHan(text) {
            return "zh-Hans"
        }
        guard let raw = detectedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "en"
        }
        let lower = raw.lowercased()
        if lower.hasPrefix("zh") { return "zh-Hans" }
        let base = lower.split(separator: "-").first.map(String.init) ?? lower
        switch base {
        case "en", "ja", "ko", "fr", "de", "es", "ru":
            return base
        default:
            return "en"
        }
    }
}

public struct OpenAICompatibleConfig: Codable, Equatable, Sendable {
    public var baseURL: String = "https://api.openai.com/v1"
    public var model: String = "gpt-4o-mini"

    public init(baseURL: String = "https://api.openai.com/v1", model: String = "gpt-4o-mini") {
        self.baseURL = baseURL
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4o-mini"
    }

    public var credentialScope: String? {
        resolvedEndpointURL().flatMap(Self.normalizedOrigin(of:))
    }

    public var allowsEmptyAPIKey: Bool {
        guard let url = resolvedEndpointURL(), let rawHost = url.host?.lowercased() else {
            return false
        }
        return Self.isLoopbackHost(rawHost)
    }

    public func resolvedEndpointURL() -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }

        let currentPath = components.path
        if !currentPath.hasSuffix("/chat/completions") {
            if currentPath.isEmpty || currentPath == "/" {
                components.path = "/v1/chat/completions"
            } else {
                let stripped = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
                components.path = stripped + "/chat/completions"
            }
        }
        guard let url = components.url, Self.isAllowedEndpointURL(url) else {
            return nil
        }
        return url
    }

    public static func normalizedOrigin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
            let rawHost = url.host?.lowercased(), !rawHost.isEmpty
        else {
            return nil
        }
        let host = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
        if let port = url.port {
            let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if !isDefaultPort {
                return "\(scheme)://\(host):\(port)"
            }
        }
        return "\(scheme)://\(host)"
    }

    public static func isAllowedEndpointURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
            let rawHost = url.host?.lowercased(), !rawHost.isEmpty
        else {
            return false
        }
        if scheme == "https" {
            return true
        }
        if scheme == "http" {
            return isPrivateOrLoopbackHost(rawHost)
        }
        return false
    }

    private static func stripBrackets(_ host: String) -> String {
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 {
            return String(host.dropFirst().dropLast())
        }
        return host
    }

    private static func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = stripBrackets(rawHost.lowercased())
        if host == "localhost" {
            return true
        }
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            let ip = UInt32(bigEndian: addr4.s_addr)
            return (ip & 0xFF00_0000) == 0x7F00_0000
        }
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            return isIPv6Loopback(addr6)
        }
        return false
    }

    private static func isPrivateOrLoopbackHost(_ rawHost: String) -> Bool {
        let host = stripBrackets(rawHost.lowercased())
        if host == "localhost" {
            return true
        }
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            let ip = UInt32(bigEndian: addr4.s_addr)
            let isLoopback = (ip & 0xFF00_0000) == 0x7F00_0000  // 127.0.0.0/8
            let isPrivate10 = (ip & 0xFF00_0000) == 0x0A00_0000  // 10.0.0.0/8
            let isPrivate172 = (ip & 0xFFF0_0000) == 0xAC10_0000  // 172.16.0.0/12
            let isPrivate192 = (ip & 0xFFFF_0000) == 0xC0A8_0000  // 192.168.0.0/16
            let isCarrierNAT = (ip & 0xFFC0_0000) == 0x6440_0000  // 100.64.0.0/10
            let isLinkLocal = (ip & 0xFFFF_0000) == 0xA9FE_0000  // 169.254.0.0/16
            return isLoopback || isPrivate10 || isPrivate172 || isPrivate192 || isCarrierNAT || isLinkLocal
        }
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            return isIPv6Loopback(addr6) || isIPv6UniqueLocalOrLinkLocal(addr6)
        }
        return false
    }

    private static func isIPv6Loopback(_ addr: in6_addr) -> Bool {
        let b = addr.__u6_addr.__u6_addr8
        return b.0 == 0 && b.1 == 0 && b.2 == 0 && b.3 == 0
            && b.4 == 0 && b.5 == 0 && b.6 == 0 && b.7 == 0
            && b.8 == 0 && b.9 == 0 && b.10 == 0 && b.11 == 0
            && b.12 == 0 && b.13 == 0 && b.14 == 0 && b.15 == 1
    }

    private static func isIPv6UniqueLocalOrLinkLocal(_ addr: in6_addr) -> Bool {
        let b = addr.__u6_addr.__u6_addr8
        let isULA = (b.0 & 0xFE) == 0xFC  // fc00::/7
        let isLinkLocal = b.0 == 0xFE && (b.1 & 0xC0) == 0x80  // fe80::/10
        return isULA || isLinkLocal
    }
}

public enum OpenAIProviderPreset: String, CaseIterable, Equatable, Sendable, Identifiable {
    case deepseek
    case openAI
    case ollama

    public var id: Self { self }

    public var title: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openAI: "OpenAI"
        case .ollama: "Ollama"
        }
    }

    public var config: OpenAICompatibleConfig {
        switch self {
        case .deepseek:
            OpenAICompatibleConfig(baseURL: "https://api.deepseek.com", model: "deepseek-chat")
        case .openAI:
            OpenAICompatibleConfig(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
        case .ollama:
            OpenAICompatibleConfig(baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5")
        }
    }
}

public struct TranslationPreferences: Codable, Equatable, Sendable {
    public var screenshotShortcut: TranslationShortcut = .defaultScreenshot
    public var engine: TranslationEngine = .apple
    public var targetLanguage: TranslationTargetLanguage = .auto
    public var mergeOCRLineBreaks = true
    public var apiConfig = OpenAICompatibleConfig()

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        screenshotShortcut =
            try values.decodeIfPresent(TranslationShortcut.self, forKey: .screenshotShortcut)
            ?? .defaultScreenshot
        engine = try values.decodeIfPresent(TranslationEngine.self, forKey: .engine) ?? .apple
        targetLanguage =
            try values.decodeIfPresent(TranslationTargetLanguage.self, forKey: .targetLanguage) ?? .auto
        mergeOCRLineBreaks = try values.decodeIfPresent(Bool.self, forKey: .mergeOCRLineBreaks) ?? true
        apiConfig =
            try values.decodeIfPresent(OpenAICompatibleConfig.self, forKey: .apiConfig)
            ?? OpenAICompatibleConfig()
    }
}

public struct RecognizedTextRegion: Equatable, Sendable {
    public var text: String
    public var normalizedBox: CGRect

    public init(text: String, normalizedBox: CGRect) {
        self.text = text
        self.normalizedBox = normalizedBox
    }
}

public struct TranslatedTextRegion: Equatable, Sendable {
    public var original: String
    public var translated: String
    public var normalizedBox: CGRect

    public init(original: String, translated: String, normalizedBox: CGRect) {
        self.original = original
        self.translated = translated
        self.normalizedBox = normalizedBox
    }
}

public enum TranslationTextNormalizer {
    public static func normalize(_ raw: String, mergeLineBreaks: Bool) -> String {
        let unix = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let outerTrimmed = unix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outerTrimmed.isEmpty else { return "" }

        if !mergeLineBreaks {
            var paragraphs = [String]()
            var blankCount = 0
            for rawLine in outerTrimmed.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = trimTrailingHorizontalWhitespace(String(rawLine))
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    blankCount += 1
                    if blankCount == 1 { paragraphs.append("") }
                } else {
                    blankCount = 0
                    paragraphs.append(line)
                }
            }
            return paragraphs.joined(separator: "\n")
        }

        let lines = outerTrimmed.split(separator: "\n", omittingEmptySubsequences: false)
        var paragraphs = [[String]]()
        var current = [String]()
        for rawLine in lines {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current.removeAll()
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs.map(joinParagraphLines).joined(separator: "\n\n")
    }

    public static func containsMostlyCJKHan(_ text: String) -> Bool {
        var cjkHanCount = 0
        var kanaCount = 0
        var asciiLetterCount = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                cjkHanCount += 1
            } else if (0x3040...0x30FF).contains(value) {
                kanaCount += 1
            } else if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
                asciiLetterCount += 1
            }
        }
        return cjkHanCount > 0 && kanaCount == 0 && cjkHanCount >= asciiLetterCount
    }

    public static func mergeHorizontalRegions(
        _ regions: [RecognizedTextRegion],
        imageSize: CGSize? = nil
    ) -> [RecognizedTextRegion] {
        let nonEmpty = regions.compactMap { region -> RecognizedTextRegion? in
            let trimmed = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, region.normalizedBox.width > 0, region.normalizedBox.height > 0 else {
                return nil
            }
            return RecognizedTextRegion(text: trimmed, normalizedBox: region.normalizedBox)
        }
        guard !nonEmpty.isEmpty else { return [] }

        let scaleX: CGFloat
        let scaleY: CGFloat
        if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            scaleX = imageSize.width
            scaleY = imageSize.height
        } else {
            scaleX = 1
            scaleY = 1
        }

        func scaledBox(_ box: CGRect) -> CGRect {
            CGRect(
                x: box.minX * scaleX,
                y: box.minY * scaleY,
                width: box.width * scaleX,
                height: box.height * scaleY)
        }

        let sortedTopToBottom = nonEmpty.sorted { lhs, rhs in
            if lhs.normalizedBox.midY != rhs.normalizedBox.midY {
                return lhs.normalizedBox.midY > rhs.normalizedBox.midY
            }
            return lhs.normalizedBox.minX < rhs.normalizedBox.minX
        }

        var rows: [[RecognizedTextRegion]] = []
        for item in sortedTopToBottom {
            let itemScaled = scaledBox(item.normalizedBox)
            if let rowIndex = rows.firstIndex(where: { row in
                let avgMidY = row.reduce(CGFloat(0)) { $0 + scaledBox($1.normalizedBox).midY } / CGFloat(row.count)
                let avgHeight = row.reduce(CGFloat(0)) { $0 + scaledBox($1.normalizedBox).height } / CGFloat(row.count)
                let minH = min(itemScaled.height, avgHeight)
                return abs(itemScaled.midY - avgMidY) < minH * 0.45
            }) {
                rows[rowIndex].append(item)
            } else {
                rows.append([item])
            }
        }

        var mergedAll: [RecognizedTextRegion] = []
        for row in rows {
            let ordered = row.sorted { $0.normalizedBox.minX < $1.normalizedBox.minX }
            guard var current = ordered.first else { continue }
            for next in ordered.dropFirst() {
                let curScaled = scaledBox(current.normalizedBox)
                let nextScaled = scaledBox(next.normalizedBox)
                let minH = min(curScaled.height, nextScaled.height)
                let maxH = max(curScaled.height, nextScaled.height)
                let midDiff = abs(curScaled.midY - nextScaled.midY)
                let gap = nextScaled.minX - curScaled.maxX
                if midDiff < minH * 0.45 && gap >= -minH * 0.3 && gap <= maxH * 1.2 {
                    let separator =
                        (isCJK(current.text.unicodeScalars.last) || isCJK(next.text.unicodeScalars.first)) ? "" : " "
                    current = RecognizedTextRegion(
                        text: current.text + separator + next.text,
                        normalizedBox: current.normalizedBox.union(next.normalizedBox))
                } else {
                    mergedAll.append(current)
                    current = next
                }
            }
            mergedAll.append(current)
        }
        return mergedAll
    }

    private static func trimTrailingHorizontalWhitespace(_ line: String) -> String {
        var result = line
        while let last = result.last, last == " " || last == "\t" {
            result.removeLast()
        }
        return result
    }

    private static func joinParagraphLines(_ lines: [String]) -> String {
        guard var joined = lines.first else { return "" }
        for next in lines.dropFirst() {
            if shouldStripHyphenJoin(previous: joined, next: next) {
                joined.removeLast()
                joined += next
            } else if isCJK(joined.unicodeScalars.last) || isCJK(next.unicodeScalars.first) {
                joined += next
            } else {
                joined += " " + next
            }
        }
        return joined
    }

    private static func shouldStripHyphenJoin(previous: String, next: String) -> Bool {
        guard previous.count >= 2, previous.last == "-" else { return false }
        let beforeHyphen = previous[previous.index(before: previous.index(before: previous.endIndex))]
        guard isASCIILetter(beforeHyphen), let firstNext = next.first, isASCIILetter(firstNext) else {
            return false
        }
        return true
    }

    private static func isASCIILetter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isCJK(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return (0x3000...0x303F).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xFF00...0xFFEF).contains(value)
    }
}
