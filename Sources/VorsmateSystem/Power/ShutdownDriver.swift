// [INPUT]: AppKit 运行应用、Darwin 信号、CFPreferences 与固定系统动作回调。
// [OUTPUT]: 可替换的关机驱动、真实应用温和与 SIGKILL 强制退出、内核回读和内存预览驱动。
// [POS]: 一键关机的系统边界；执行前再次核对进程身份，禁止任意命令或路径。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Darwin
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
    private func canTerminate(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, let id = app.bundleIdentifier,
            id != Bundle.main.bundleIdentifier, id != "app.vorsmate.mac", id != "com.apple.finder",
            let path = app.bundleURL?.path,
            !path.hasPrefix("/System/Library/"), !path.hasPrefix("/Library/Apple/")
        else { return false }
        let pid = app.processIdentifier
        return pid > 1 && pid != ProcessInfo.processInfo.processIdentifier
    }
    private func eligible(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && canTerminate(app)
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
        item.pids.compactMap { pid -> NSRunningApplication? in
            guard pid > 1 else { return nil }
            guard Darwin.kill(pid, 0) == 0 || errno == EPERM else { return nil }
            guard let app = NSRunningApplication(processIdentifier: pid),
                !app.isTerminated,
                app.bundleIdentifier == item.bundleID
            else { return nil }
            return app
        }
    }
    public func disableReopenWindows() throws {
        let domain = "com.apple.loginwindow" as CFString
        CFPreferencesSetAppValue("TALLogoutSavesState" as CFString, kCFBooleanFalse, domain)
        CFPreferencesSetAppValue("LoginwindowLaunchesRelaunchApps" as CFString, kCFBooleanFalse, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw ShutdownFailure.message("无法保存下次开机不恢复窗口的设置，操作已停止。")
        }
        CFPreferencesSetValue(
            "TALAppsToRelaunchAtLogin" as CFString, [] as CFArray, domain,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
    public func terminate(_ app: RunningAppItem, force: Bool) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for process in processes(app) where canTerminate(process) {
            if force {
                _ = process.forceTerminate()
                let pid = process.processIdentifier
                if pid > 1 && pid != ownPID && Darwin.kill(pid, 0) == 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            } else {
                _ = process.terminate()
            }
        }
    }
    public func isRunning(_ app: RunningAppItem) -> Bool { !processes(app).isEmpty }
    public func execute(_ action: ShutdownAction) async throws { try await systemAction(action) }
    public static func appleScript(_ action: ShutdownAction) async throws {
        let command = action == .shutdown ? "shut down" : "restart"
        let failure = await Task.detached(priority: .userInitiated) { () -> (Int?, String)? in
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application \"System Events\" to \(command)")
            let result = script?.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int
                let detail =
                    (error[NSAppleScript.errorBriefMessage] as? String)
                    ?? (error[NSAppleScript.errorMessage] as? String)
                    ?? error.description
                return (code, detail)
            }
            if result == nil {
                return (nil, "无法构造系统事件脚本。")
            }
            return nil
        }.value
        if let failure {
            throw ShutdownFailure.message(appleScriptErrorMessage(code: failure.0, detail: failure.1, action: action))
        }
    }
    public static func appleScriptErrorMessage(code: Int?, detail: String, action: ShutdownAction) -> String {
        if code == -1743 {
            return "未获授权控制 System Events，无法\(action.title)。请在「系统设置 → 隐私与安全性 → 自动化」中允许 Vorsmate 控制 System Events。"
        }
        return "系统未接受\(action.title)：\(detail)"
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
    public init(longList: Bool = false) {
        if longList {
            let names = ["项目资料与协作笔记编辑器", "日历", "邮件", "图像编辑器", "音乐", "文件传输", "视频会议", "阅读器"]
            apps += names.enumerated().map { index, name in
                RunningAppItem(bundleID: "preview.extra.\(index)", name: name, pids: [pid_t(105 + index)])
            }
        }
    }
    public func runningApps() -> [RunningAppItem] { apps }
    public func disableReopenWindows() throws {}
    public func terminate(_ app: RunningAppItem, force: Bool) { apps.removeAll { $0.id == app.id } }
    public func isRunning(_ app: RunningAppItem) -> Bool { apps.contains { $0.id == app.id } }
    public func execute(_ action: ShutdownAction) async throws {}
}
