// [INPUT]: AppKit 运行应用、CFPreferences 与固定系统动作回调。
// [OUTPUT]: 可替换的关机驱动、真实应用清理与完全内存的预览驱动。
// [POS]: 一键下班的系统边界；执行前再次核对进程身份，禁止任意命令或路径。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import VorsmateCore

@MainActor
public protocol ShutdownDriver: AnyObject {
    var isPreview: Bool { get }
    func runningApps() -> [RunningAppItem]
    func disableReopenWindows() throws
    func terminate(_ app: RunningAppItem, force: Bool)
    func isRunning(_ app: RunningAppItem) -> Bool
    func execute(_ action: ShutdownAction) async throws
}

@MainActor
public final class SystemShutdownDriver: ShutdownDriver {
    public let isPreview = false
    private let systemAction: @MainActor (ShutdownAction) async throws -> Void
    public init(
        systemAction: @escaping @MainActor (ShutdownAction) async throws -> Void = SystemShutdownDriver.appleScript
    ) {
        self.systemAction = systemAction
    }
    private func eligible(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier,
            id != Bundle.main.bundleIdentifier, id != "app.vorsmate.mac", id != "com.apple.finder",
            let path = app.bundleURL?.path,
            !path.hasPrefix("/System/Library/"), !path.hasPrefix("/Library/Apple/")
        else { return false }
        return app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
    public func runningApps() -> [RunningAppItem] {
        let groups = Dictionary(grouping: NSWorkspace.shared.runningApplications.filter(eligible)) {
            $0.bundleIdentifier!
        }
        return groups.map { id, apps in
            RunningAppItem(
                bundleID: id, name: apps.first?.localizedName ?? id, pids: apps.map(\.processIdentifier).sorted())
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func processes(_ item: RunningAppItem) -> [NSRunningApplication] {
        item.pids.compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { eligible($0) && $0.bundleIdentifier == item.bundleID }
    }
    public func disableReopenWindows() throws {
        let domain = "com.apple.loginwindow" as CFString
        CFPreferencesSetAppValue("TALLogoutSavesState" as CFString, kCFBooleanFalse, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw ShutdownFailure.message("无法保存下次开机不恢复窗口的设置，操作已停止。")
        }
    }
    public func terminate(_ app: RunningAppItem, force: Bool) {
        for process in processes(app) {
            if force { process.forceTerminate() } else { process.terminate() }
        }
    }
    public func isRunning(_ app: RunningAppItem) -> Bool { !processes(app).isEmpty }
    public func execute(_ action: ShutdownAction) async throws { try await systemAction(action) }
    public static func appleScript(_ action: ShutdownAction) async throws {
        let command = action == .shutdown ? "shut down" : "restart"
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to \(command)")?.executeAndReturnError(&error)
        if let error {
            throw ShutdownFailure.message("系统未接受\(action.title)：\(error)。可在风扇模块启用助手后重试。")
        }
    }
}

public enum ShutdownFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

@MainActor
public final class PreviewShutdownDriver: ShutdownDriver {
    public let isPreview = true
    private var apps = [
        RunningAppItem(bundleID: "preview.editor", name: "文稿编辑器", pids: [101]),
        RunningAppItem(bundleID: "preview.browser", name: "浏览器", pids: [102, 103]),
        RunningAppItem(bundleID: "preview.notes", name: "笔记", pids: [104]),
    ]
    public init() {}
    public func runningApps() -> [RunningAppItem] { apps }
    public func disableReopenWindows() throws {}
    public func terminate(_ app: RunningAppItem, force: Bool) { apps.removeAll { $0.id == app.id } }
    public func isRunning(_ app: RunningAppItem) -> Bool { apps.contains { $0.id == app.id } }
    public func execute(_ action: ShutdownAction) async throws {}
}
