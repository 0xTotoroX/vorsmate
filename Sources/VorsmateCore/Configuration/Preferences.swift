// [INPUT]: Foundation 文件系统、SelectionPolicy、插件 / 风扇 / 关机配置。
// [OUTPUT]: 带版本的 Preferences；在目录锁内核对预期值并原子写入配置。
// [POS]: 唯一配置持久化入口；损坏或未来版本不自动覆盖。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Darwin
import Foundation

// The directory stays in place when an atomic write replaces the file or promotes a v1 profile to v2.
func withConfigurationWriteLock(at url: URL, timeoutSeconds: TimeInterval = 1.5, _ write: () throws -> Void) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer {
        flock(fd, LOCK_UN)
        close(fd)
    }
    let timeoutNanos = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
    let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanos
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if errno == EINTR { continue }
        if errno != EWOULDBLOCK {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
        }
        usleep(10_000)
    }
    try write()
}

public struct Preferences: Codable, Equatable, Sendable {
    public var version = 1
    public var policies: [String: SelectionPolicy] = [:]
    public var disabledPlugins: Set<PluginID> = []
    public var windowDragEnabled = false
    public var windowDragModifier: WindowDragModifier = .option
    public var remoteEnabled = false
    public var translateEnabled = false
    public var tasksEnabled = false
    public var weatherEnabled = false
    public var marketsEnabled = false
    public var weatherCity: WeatherCity?
    public var disabledAtRuntime: Set<PluginID> {
        get {
            var disabled = disabledPlugins
            if !remoteEnabled { disabled.insert(.remote) } else { disabled.remove(.remote) }
            if !translateEnabled { disabled.insert(.translate) } else { disabled.remove(.translate) }
            if !tasksEnabled { disabled.insert(.tasks) } else { disabled.remove(.tasks) }
            if !weatherEnabled { disabled.insert(.weather) } else { disabled.remove(.weather) }
            if !marketsEnabled { disabled.insert(.markets) } else { disabled.remove(.markets) }
            if !windowDragEnabled { disabled.insert(.windowDrag) } else { disabled.remove(.windowDrag) }
            return disabled
        }
        set {
            windowDragEnabled = !newValue.contains(.windowDrag)
            remoteEnabled = !newValue.contains(.remote)
            translateEnabled = !newValue.contains(.translate)
            tasksEnabled = !newValue.contains(.tasks)
            weatherEnabled = !newValue.contains(.weather)
            marketsEnabled = !newValue.contains(.markets)
            disabledPlugins = newValue.subtracting([.remote, .translate, .tasks, .weather, .markets, .windowDrag])
        }
    }
    public var fanProfiles: [Int: FanProfile] = [:]
    public var shutdownPolicy = ShutdownPolicy()
    public var translation = TranslationPreferences()
    public var unattendedAuth = UnattendedAuthPreferences()
    public var pluginOrder: [PluginID] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case windowDragEnabled, windowDragModifier
        case version, policies, disabledPlugins, remoteEnabled, translateEnabled, tasksEnabled, fanProfiles,
            shutdownPolicy, translation, unattendedAuth, pluginOrder
        case weatherEnabled, marketsEnabled, weatherCity
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        policies = try values.decodeIfPresent([String: SelectionPolicy].self, forKey: .policies) ?? [:]
        disabledPlugins = try values.decodeIfPresent(Set<PluginID>.self, forKey: .disabledPlugins) ?? []
        windowDragEnabled = try values.decodeIfPresent(Bool.self, forKey: .windowDragEnabled) ?? false
        windowDragModifier = try values.decodeIfPresent(WindowDragModifier.self, forKey: .windowDragModifier) ?? .option
        remoteEnabled = try values.decodeIfPresent(Bool.self, forKey: .remoteEnabled) ?? false
        translateEnabled = try values.decodeIfPresent(Bool.self, forKey: .translateEnabled) ?? false
        tasksEnabled = try values.decodeIfPresent(Bool.self, forKey: .tasksEnabled) ?? false
        weatherEnabled = try values.decodeIfPresent(Bool.self, forKey: .weatherEnabled) ?? false
        marketsEnabled = try values.decodeIfPresent(Bool.self, forKey: .marketsEnabled) ?? false
        weatherCity = try values.decodeIfPresent(WeatherCity.self, forKey: .weatherCity)
        fanProfiles = try values.decodeIfPresent([Int: FanProfile].self, forKey: .fanProfiles) ?? [:]
        shutdownPolicy = try values.decodeIfPresent(ShutdownPolicy.self, forKey: .shutdownPolicy) ?? ShutdownPolicy()
        translation =
            try values.decodeIfPresent(TranslationPreferences.self, forKey: .translation)
            ?? TranslationPreferences()
        unattendedAuth =
            try values.decodeIfPresent(UnattendedAuthPreferences.self, forKey: .unattendedAuth)
            ?? UnattendedAuthPreferences()
        pluginOrder = try values.decodeIfPresent([PluginID].self, forKey: .pluginOrder) ?? []
    }
    public func resolvedOrder(from candidates: [PluginID]) -> [PluginID] {
        let candidateSet = Set(candidates)
        var seen: Set<PluginID> = []
        var result: [PluginID] = []
        result.reserveCapacity(candidates.count)
        for id in pluginOrder where candidateSet.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        for id in candidates where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
    public static func movedOrder(_ current: [PluginID], moving id: PluginID, by offset: Int) -> [PluginID] {
        guard offset != 0, let index = current.firstIndex(of: id), !current.isEmpty else {
            return current
        }
        let target = min(current.count - 1, max(0, index + offset))
        guard target != index else { return current }
        var next = current
        let item = next.remove(at: index)
        next.insert(item, at: target)
        return next
    }
    public func reorderedPluginOrder(
        moving id: PluginID, within category: PluginCategory, by offset: Int,
        available: [PluginID] = PluginID.allCases
    ) -> [PluginID] {
        var fullOrder = resolvedOrder(from: PluginID.allCases)
        let visible = Set(available)
        let slots = fullOrder.indices.filter { category.canReorder(fullOrder[$0]) && visible.contains(fullOrder[$0]) }
        let members = slots.map { fullOrder[$0] }
        let reordered = Self.movedOrder(members, moving: id, by: offset)
        guard reordered != members else { return pluginOrder }

        for (slot, item) in zip(slots, reordered) {
            fullOrder[slot] = item
        }
        return fullOrder == PluginID.allCases ? [] : fullOrder
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try withConfigurationWriteLock(at: url) {
            if let expected, try load() != expected { throw PreferenceError.changedOnDisk }
            try data.write(to: url, options: .atomic)
        }
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
