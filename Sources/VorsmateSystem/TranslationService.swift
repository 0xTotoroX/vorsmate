// [INPUT]: Security 钥匙串、NaturalLanguage 语种识别、URLSession 与 VorsmateCore 翻译配置。
// [OUTPUT]: API 密钥安全存储、语种解析与 OpenAI 兼容批量翻译客户端（含可替换网络替身）。
// [POS]: VorsmateSystem 翻译引擎服务层；API 密钥仅存本机非同步钥匙串，不写配置或日志。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import NaturalLanguage
import Security
import VorsmateCore

public protocol TranslationAPIKeyStore: Sendable {
    func hasAPIKey(forScope scope: String) -> Bool
    func loadAPIKey(forScope scope: String) throws -> String?
    func saveAPIKey(_ key: String, forScope scope: String) throws
    func deleteAPIKey(forScope scope: String) throws
}

public enum TranslationKeychainError: LocalizedError, Equatable, Sendable {
    case status(OSStatus)
    case invalidEncoding

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "钥匙串操作失败：\(message)（\(status)）"
            }
            return "钥匙串操作失败（\(status)）"
        case .invalidEncoding:
            return "无法解析钥匙串中保存的接口密钥。"
        }
    }
}

public struct KeychainTranslationAPIKeyStore: TranslationAPIKeyStore {
    private let service: String

    public init(service: String = "app.vorsmate.mac.translation-api") {
        self.service = service
    }

    private static func normalizedAccount(forScope scope: String) -> String {
        "origin:\(scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func baseQuery(forScope scope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.normalizedAccount(forScope: scope),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func hasAPIKey(forScope scope: String) -> Bool {
        var query = baseQuery(forScope: scope)
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func loadAPIKey(forScope scope: String) throws -> String? {
        var query = baseQuery(forScope: scope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TranslationKeychainError.status(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw TranslationKeychainError.invalidEncoding
        }
        return key
    }

    public func saveAPIKey(_ key: String, forScope scope: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteAPIKey(forScope: scope)
            return
        }
        let data = Data(trimmed.utf8)
        let query = baseQuery(forScope: scope)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Vorsmate 截图翻译模型密钥",
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw TranslationKeychainError.status(updateStatus)
        }
        var addQuery = query
        for (key, value) in attributes { addQuery[key] = value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TranslationKeychainError.status(addStatus)
        }
    }

    public func deleteAPIKey(forScope scope: String) throws {
        let status = SecItemDelete(baseQuery(forScope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TranslationKeychainError.status(status)
        }
    }
}

public final class InMemoryTranslationAPIKeyStore: TranslationAPIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String]

    public init(initialKeys: [String: String] = [:]) {
        var normalized: [String: String] = [:]
        for (scope, key) in initialKeys {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                normalized[Self.normalizedScope(scope)] = trimmedKey
            }
        }
        self.stored = normalized
    }

    private static func normalizedScope(_ scope: String) -> String {
        scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func hasAPIKey(forScope scope: String) -> Bool {
        let normalized = Self.normalizedScope(scope)
        return lock.withLock {
            guard let key = stored[normalized] else { return false }
            return !key.isEmpty
        }
    }

    public func loadAPIKey(forScope scope: String) throws -> String? {
        let normalized = Self.normalizedScope(scope)
        return lock.withLock { stored[normalized] }
    }

    public func saveAPIKey(_ key: String, forScope scope: String) throws {
        let normalized = Self.normalizedScope(scope)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            if trimmed.isEmpty {
                stored.removeValue(forKey: normalized)
            } else {
                stored[normalized] = trimmed
            }
        }
    }

    public func deleteAPIKey(forScope scope: String) throws {
        let normalized = Self.normalizedScope(scope)
        lock.withLock {
            _ = stored.removeValue(forKey: normalized)
        }
    }
}

public enum TranslationServiceError: LocalizedError, Equatable, Sendable {
    case unsupportedOS
    case languageUnsupported(String)
    case missingAPIKey
    case invalidEndpoint
    case networkFailure(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "系统离线翻译需要 macOS 15 及以上系统，请切换为自定义模型接口。"
        case .languageUnsupported(let detail):
            return "系统离线翻译暂不支持当前语言组合：\(detail)"
        case .missingAPIKey:
            return "尚未配置模型接口密钥，请在菜单栏「截图」展开栏填写并保存密钥。"
        case .invalidEndpoint:
            return "模型接口地址无效（仅允许 HTTPS，或本机／局域网 HTTP 网关）。"
        case .networkFailure(let detail):
            return "翻译请求失败：\(detail)"
        case .invalidResponse(let detail):
            return "翻译接口返回异常：\(detail)"
        }
    }
}

public enum TranslationLanguageDetector {
    public static func detectAndResolve(
        for text: String, target: TranslationTargetLanguage
    ) -> (source: String, target: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let dominant = recognizer.dominantLanguage?.rawValue
        return target.resolveLanguages(for: text, detectedLanguage: dominant)
    }
}

public protocol OpenAITranslationTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionOpenAITransport: OpenAITranslationTransport {
    private let session: URLSession

    public init(timeoutInterval: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval
        self.init(configuration: config)
    }

    public init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration, delegate: RedirectGuardDelegate(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranslationServiceError.invalidResponse("未收到有效 HTTP 响应")
        }
        if (300...399).contains(http.statusCode) {
            if let location = http.value(forHTTPHeaderField: "Location"),
                let baseURL = request.url,
                let resolved = URL(string: location, relativeTo: baseURL)?.absoluteURL,
                !OpenAICompatibleConfig.isAllowedEndpointURL(resolved)
            {
                throw TranslationServiceError.invalidEndpoint
            }
            throw TranslationServiceError.invalidResponse("已拦截不安全或跨源重定向")
        }
        return (data, http)
    }

    private final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard
                let originalURL = task.originalRequest?.url,
                let targetURL = request.url,
                OpenAICompatibleConfig.isAllowedEndpointURL(targetURL),
                let originalOrigin = OpenAICompatibleConfig.normalizedOrigin(of: originalURL),
                let targetOrigin = OpenAICompatibleConfig.normalizedOrigin(of: targetURL),
                originalOrigin == targetOrigin
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}

public struct OpenAICompatibleTranslator: Sendable {
    private let transport: any OpenAITranslationTransport

    public init(transport: any OpenAITranslationTransport = URLSessionOpenAITransport()) {
        self.transport = transport
    }

    public func translateBatch(
        _ texts: [String],
        source: String,
        target: String,
        config: OpenAICompatibleConfig,
        apiKey: String
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        guard let endpointURL = config.resolvedEndpointURL() else {
            throw TranslationServiceError.invalidEndpoint
        }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw TranslationServiceError.invalidResponse("模型名称不能为空")
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty && !config.allowsEmptyAPIKey {
            throw TranslationServiceError.missingAPIKey
        }

        let targetDescription = Self.languageDisplayName(target)
        let systemPrompt: String
        let userContent: String
        if texts.count == 1 {
            systemPrompt =
                "You are a concise translator. Translate the user text into \(targetDescription). Output only the translated text with no quotes, explanations, or markdown."
            userContent = texts[0]
        } else {
            systemPrompt =
                "You are a concise translator. Translate each string in the JSON array field `items` into \(targetDescription), preserving exact count and order. Respond ONLY with valid JSON: {\"translations\": [\"...\"]}."
            let payloadData = try JSONEncoder().encode(BatchInput(items: texts))
            userContent = String(decoding: payloadData, as: UTF8.self)
        }

        let requestBody = ChatCompletionRequest(
            model: model,
            temperature: 0.1,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent),
            ])

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let error as TranslationServiceError {
            throw error
        } catch {
            throw TranslationServiceError.networkFailure(error.localizedDescription)
        }

        guard (200...299).contains(http.statusCode) else {
            let apiMessage =
                (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.message)
                ?? "HTTP \(http.statusCode)"
            throw TranslationServiceError.invalidResponse(apiMessage)
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw TranslationServiceError.invalidResponse("无法解析模型响应")
        }
        guard
            let rawContent = decoded.choices.first?.message.content?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawContent.isEmpty
        else {
            throw TranslationServiceError.invalidResponse("模型返回内容为空")
        }

        if texts.count == 1 {
            return [rawContent]
        }
        return try Self.parseBatchContent(rawContent, expectedCount: texts.count)
    }

    private static func parseBatchContent(_ raw: String, expectedCount: Int) throws -> [String] {
        let cleaned = stripCodeFence(raw)
        guard let jsonData = cleaned.data(using: .utf8) else {
            throw TranslationServiceError.invalidResponse("批量译文格式解析失败")
        }
        let values: [String]
        if let object = try? JSONDecoder().decode(BatchOutput.self, from: jsonData) {
            values = object.translations
        } else if let array = try? JSONDecoder().decode([String].self, from: jsonData) {
            values = array
        } else {
            throw TranslationServiceError.invalidResponse("批量译文格式解析失败")
        }
        guard values.count == expectedCount else {
            throw TranslationServiceError.invalidResponse(
                "批量译文数量不匹配（预期 \(expectedCount) 条，实际返回 \(values.count) 条）")
        }
        return values
    }

    private static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3))
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func languageDisplayName(_ code: String) -> String {
        switch code {
        case "zh-Hans": "Simplified Chinese"
        case "en": "English"
        case "ja": "Japanese"
        default: code
        }
    }

    private struct BatchInput: Encodable {
        let items: [String]
    }

    private struct BatchOutput: Decodable {
        let translations: [String]
    }

    private struct ChatCompletionRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let temperature: Double
        let messages: [Message]
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let message: String
        }
        let error: Detail
    }
}
