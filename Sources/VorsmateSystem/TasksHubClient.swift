// [INPUT]: Foundation URLSession、HubRuntimeInfo 与 ReminderTree 模型。
// [OUTPUT]: 0xTotoro Local Hub HTTP 客户端与可替换网络传输协议。
// [POS]: VorsmateSystem 待办连接层；仅访问本机回环 Hub，未启动或配置缺失时返回安全错误。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import VorsmateCore

public protocol TasksHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTasksHubTransport: TasksHubTransport {
    private let session: URLSession

    public init(timeoutInterval: TimeInterval = 5) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval
        self.init(configuration: config)
    }

    public init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
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
        } catch {
            throw TasksHubError.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw TasksHubError.invalidResponse
        }
        return (data, http)
    }

    private final class LoopbackRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

public enum TasksHubError: LocalizedError, Equatable, Sendable {
    case unconfigured
    case unreachable
    case unauthorized
    case invalidResponse
    case httpError(Int)

    public var isOfflineLike: Bool {
        switch self {
        case .unconfigured, .unreachable, .unauthorized: true
        case .invalidResponse, .httpError: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unconfigured: "未检测到本地 0xTotoro Hub 配置"
        case .unreachable: "未能连接到本地 0xTotoro Hub"
        case .unauthorized: "本地 Hub 鉴权失败"
        case .invalidResponse: "本地 Hub 返回格式异常"
        case .httpError(let code): "本地 Hub 请求失败（HTTP \(code)）"
        }
    }
}

public protocol TasksHubClientProtocol: Sendable {
    func fetchTree(includeCompleted: Bool) async throws -> ReminderTree
    func setCompleted(itemID: String, completed: Bool) async throws
    func createItem(title: String, listID: String) async throws
}

public struct TasksHubClient: TasksHubClientProtocol {
    private let runtimeFileURL: URL
    private let transport: any TasksHubTransport

    public init(
        runtimeFileURL: URL = HubRuntimeInfo.defaultRuntimeURL(),
        transport: any TasksHubTransport = URLSessionTasksHubTransport()
    ) {
        self.runtimeFileURL = runtimeFileURL
        self.transport = transport
    }

    public func fetchTree(includeCompleted: Bool = false) async throws -> ReminderTree {
        let (baseURL, token) = try loadRuntime()
        guard
            var components = URLComponents(
                url: baseURL.appending(path: "api/reminders/tree"),
                resolvingAgainstBaseURL: false
            )
        else {
            throw TasksHubError.unconfigured
        }
        components.queryItems = [URLQueryItem(name: "include_completed", value: includeCompleted ? "true" : "false")]
        guard let url = components.url else { throw TasksHubError.unconfigured }

        let request = authorizedRequest(url: url, method: "GET", token: token)
        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(ReminderTree.self, from: data)
        } catch {
            throw TasksHubError.invalidResponse
        }
    }

    public func setCompleted(itemID: String, completed: Bool) async throws {
        let (baseURL, token) = try loadRuntime()
        let url = baseURL.appending(path: "api/reminders/items").appending(path: itemID)
        var request = authorizedRequest(url: url, method: "PATCH", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CompleteItemPayload(completed: completed))
        _ = try await perform(request)
    }

    public func createItem(title: String, listID: String) async throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !listID.isEmpty else { return }
        let (baseURL, token) = try loadRuntime()
        let url = baseURL.appending(path: "api/reminders/items")
        var request = authorizedRequest(url: url, method: "POST", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateItemPayload(title: trimmedTitle, listID: listID))
        _ = try await perform(request)
    }

    private func loadRuntime() throws -> (URL, String) {
        guard let info = try? HubRuntimeInfo.load(from: runtimeFileURL),
            let baseURL = info.resolvedBaseURL
        else {
            throw TasksHubError.unconfigured
        }
        return (baseURL, info.token)
    }

    private func authorizedRequest(url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, http) = try await transport.send(request)
        if http.statusCode == 401 || http.statusCode == 403 {
            throw TasksHubError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw TasksHubError.httpError(http.statusCode)
        }
        return data
    }

    private struct CompleteItemPayload: Encodable {
        let completed: Bool
    }

    private struct CreateItemPayload: Encodable {
        let title: String
        let listID: String

        enum CodingKeys: String, CodingKey {
            case title
            case listID = "list_id"
        }
    }
}
