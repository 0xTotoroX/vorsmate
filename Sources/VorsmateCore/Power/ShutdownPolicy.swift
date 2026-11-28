// [INPUT]: Foundation Codable 与 Darwin 进程标识。
// [OUTPUT]: 关机 / 重启动作、清理偏好、按 Bundle ID 聚合的应用条目与菜单栏状态格式化。
// [POS]: 一键关机的纯数据契约，不访问进程或执行系统命令。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum ShutdownAction: String, Codable, CaseIterable, Sendable {
    case shutdown, restart
    public var title: String { self == .shutdown ? "关机" : "重启" }
}

public enum ShutdownStatusFormatter {
    public static func menuBarTitle(
        countdown: Int?,
        action: ShutdownAction?,
        executing: Bool,
        submitting: Bool
    ) -> String? {
        if submitting, let action { return "正在\(action.title)" }
        if executing { return "正在退出应用" }
        if let countdown, let action { return "\(countdown) 秒后\(action.title)" }
        return nil
    }

    public static func menuBarTooltip(
        countdown: Int?,
        action: ShutdownAction?,
        executing: Bool,
        submitting: Bool
    ) -> String? {
        if submitting, let action { return "正在提交\(action.title)请求" }
        if executing, let action { return "正在退出应用 · 右键取消\(action.title)" }
        if let countdown, let action { return "\(countdown) 秒后\(action.title) · 右键取消" }
        return nil
    }
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
