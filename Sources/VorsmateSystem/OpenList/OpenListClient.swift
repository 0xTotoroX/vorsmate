// [INPUT]: 私有 OpenList 本机连接器的固定命令、文本状态与回环网页登录地址。
// [OUTPUT]: 网盘挂载状态、按需启停和网页入口；安全停止保留连接器的互斥和待上传检查。
// [POS]: VorsmateSystem 本机适配器，使用用户提供的 Python 入口，配置和凭据留在原目录。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct OpenListStatus: Equatable, Sendable {
    public let mounted: Int
    public let total: Int
    public let connectionLoaded: Bool

    public init(mounted: Int, total: Int, connectionLoaded: Bool) {
        self.mounted = mounted
        self.total = total
        self.connectionLoaded = connectionLoaded
    }

    init(output: String) throws {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let connection = lines.last, lines.count > 1,
            connection == "专用连接：已加载" || connection == "专用连接：已关闭"
        else { throw OpenListError.invalidResponse }
        let volumes = lines.dropLast()
        guard volumes.allSatisfy({ $0.hasSuffix("：已开启") || $0.hasSuffix("：已关闭") }) else {
            throw OpenListError.invalidResponse
        }
        self.init(
            mounted: volumes.count(where: { $0.hasSuffix("：已开启") }),
            total: volumes.count, connectionLoaded: connection == "专用连接：已加载")
    }
}

public enum OpenListError: LocalizedError, Sendable, Equatable {
    case missingConnector
    case unavailable
    case invalidResponse
    case operationRejected(String)

    public var errorDescription: String? {
        switch self {
        case .missingConnector: "请先配置本机网盘连接器。"
        case .unavailable: "无法运行网盘连接器。"
        case .invalidResponse: "网盘连接器返回了无法识别的结果。"
        case .operationRejected(let message): message
        }
    }
}

public protocol OpenListClientProtocol: Sendable {
    func status() async throws -> OpenListStatus
    func start() async throws
    func stop() async throws
    func webInterface() async throws -> URL
}

public struct OpenListClient: OpenListClientProtocol {
    public static let connectorDirectory = URL.applicationSupportDirectory
        .appending(path: "OpenList-OnDemand/Connector", directoryHint: .isDirectory)
    private static let python = URL(fileURLWithPath: "/usr/bin/python3")
    private let runner: URL
    private let run: LocalToolProcess.Run

    public init() {
        self.init(runner: Self.connectorDirectory.appending(path: "runner.py"), run: LocalToolProcess.run)
    }

    init(runner: URL, run: @escaping LocalToolProcess.Run) {
        self.runner = runner
        self.run = run
    }

    public func status() async throws -> OpenListStatus {
        try await OpenListStatus(output: execute(.status))
    }

    public func start() async throws { _ = try await execute(.start) }
    public func stop() async throws { _ = try await execute(.stop) }

    public func webInterface() async throws -> URL {
        let value = try await execute(.gui)
        guard let components = URLComponents(string: value), components.scheme == "http",
            components.host == "127.0.0.1", components.port != nil, components.path == "/login",
            components.user == nil, components.password == nil, let url = components.url
        else { throw OpenListError.invalidResponse }
        return url
    }

    private enum Command: String {
        case status, start, stop, gui
    }

    private func execute(_ command: Command) async throws -> String {
        guard let values = try? runner.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true
        else { throw OpenListError.missingConnector }
        let result: LocalToolResult
        do {
            result = try await run(Self.python, ["-B", runner.path, command.rawValue])
        } catch {
            throw OpenListError.unavailable
        }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            // Preserve a safe local explanation without surfacing CLI URLs or credential-bearing output.
            let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let lowered = line.lowercased()
            if !line.isEmpty, line.count <= 200, !lowered.contains("://"),
                !lowered.contains("pass="), !lowered.contains("password"), !lowered.contains("authorization")
            {
                throw OpenListError.operationRejected(line)
            }
            throw OpenListError.unavailable
        }
        return value
    }
}
