// [INPUT]: 当前用户目录与本机连接器运行信息。
// [OUTPUT]: 发现新旧配对文件并解析本机地址。
// [POS]: 独立于待办内容的连接配置。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct HubRuntimeInfo: Codable, Equatable, Sendable {
    public var url: String?
    public var port: Int?
    public var token: String
    public var pid: Int?

    public init(url: String? = nil, port: Int? = nil, token: String, pid: Int? = nil) {
        self.url = url
        self.port = port
        self.token = token
        self.pid = pid
    }

    public static func defaultRuntimeURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let shared = homeDirectory.appending(path: "Library/Application Support/RemindersConnector/runtime.json")
        let legacy = homeDirectory.appending(path: ".local/share/0xTotoro/runtime.json")
        if !FileManager.default.fileExists(atPath: shared.path), FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return shared
    }

    public static func load(from url: URL) throws -> HubRuntimeInfo? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(HubRuntimeInfo.self, from: data)
    }

    public var resolvedBaseURL: URL? {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return nil }

        if let rawURL = url?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty,
            let parsed = URL(string: rawURL),
            Self.isAllowedLoopbackURL(parsed)
        {
            return parsed
        }

        if let port, (1...65535).contains(port) {
            return URL(string: "http://127.0.0.1:\(port)")
        }
        return nil
    }

    public static func isAllowedLoopbackURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http",
            let host = url.host?.lowercased()
        else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
