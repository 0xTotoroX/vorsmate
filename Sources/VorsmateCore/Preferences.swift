// [INPUT]: Foundation 文件系统、SelectionPolicy、插件 / 风扇 / 关机配置。
// [OUTPUT]: 带版本的 Preferences、核对预期值后原子写入的 PreferencesStore。
// [POS]: 唯一配置持久化入口；损坏或未来版本不自动覆盖。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct Preferences: Codable, Equatable, Sendable {
    public var version = 1
    public var policies: [String: SelectionPolicy] = [:]
    public var disabledPlugins: Set<PluginID> = []
    public var fanProfiles: [Int: FanProfile] = [:]
    public var shutdownPolicy = ShutdownPolicy()
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case version, policies, disabledPlugins, fanProfiles, shutdownPolicy
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        policies = try values.decodeIfPresent([String: SelectionPolicy].self, forKey: .policies) ?? [:]
        disabledPlugins = try values.decodeIfPresent(Set<PluginID>.self, forKey: .disabledPlugins) ?? []
        fanProfiles = try values.decodeIfPresent([Int: FanProfile].self, forKey: .fanProfiles) ?? [:]
        shutdownPolicy = try values.decodeIfPresent(ShutdownPolicy.self, forKey: .shutdownPolicy) ?? ShutdownPolicy()
    }
    public subscript(channel: Channel) -> SelectionPolicy {
        get { policies[channel.rawValue] ?? SelectionPolicy() }
        set { policies[channel.rawValue] = newValue }
    }
}

public struct PreferencesStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static var standard: Self {
        Self(url: URL.applicationSupportDirectory.appending(path: "Vorsmate/settings.json"))
    }
    public func load() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return Preferences() }
        let value = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        guard value.version == 1 else {
            throw PreferenceError.unsupportedVersion(value.version)
        }
        return value
    }
    public func save(_ value: Preferences, replacing expected: Preferences? = nil) throws {
        if let expected, try load() != expected { throw PreferenceError.changedOnDisk }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public enum PreferenceError: LocalizedError {
    case unsupportedVersion(Int)
    case changedOnDisk
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "此配置需要更新的 Vorsmate（配置版本 \(version)）。"
        case .changedOnDisk: "配置已在其他位置修改。请重新打开 Vorsmate 以加载最新配置。"
        }
    }
}
