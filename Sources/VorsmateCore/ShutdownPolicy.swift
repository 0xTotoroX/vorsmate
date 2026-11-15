// [INPUT]: Foundation Codable 与 Darwin 进程标识。
// [OUTPUT]: 关机 / 重启动作、清理偏好和按 Bundle ID 聚合的应用条目。
// [POS]: 一键下班的纯数据契约，不访问进程或执行系统命令。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum ShutdownAction: String, Codable, CaseIterable, Sendable {
    case shutdown, restart
    public var title: String { self == .shutdown ? "关机" : "重启" }
}

public struct ShutdownPolicy: Codable, Equatable, Sendable {
    public var forceCloseApps = true
    public var disableReopenWindows = true
    public var excludedBundleIDs: Set<String> = []
    public init() {}
}

public struct RunningAppItem: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let pids: [pid_t]
    public init(bundleID: String, name: String, pids: [pid_t]) {
        self.bundleID = bundleID
        self.name = name
        self.pids = pids
    }
}
