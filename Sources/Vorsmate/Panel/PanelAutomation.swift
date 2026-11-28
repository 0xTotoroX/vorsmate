// [INPUT]: 当前 App 包、同一登录会话的开始 / 结束命令。
// [OUTPUT]: 有时限的面板保持状态，关闭面板或结束操作时清除。
// [POS]: 仅协调真实菜单栏弹层的自动化交互。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit

@MainActor
final class PanelAutomation {
    private enum Action: String { case begin, end }
    private static let notification = Notification.Name("app.vorsmate.mac.panel-automation")
    private static let timeout: Duration = .seconds(120)
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var session: UUID?
    private let onChange: () -> Void

    var isActive: Bool { session != nil }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    static func send(_ arguments: ArraySlice<String>) {
        guard arguments.count == 2, let name = arguments.first, let action = Action(rawValue: name),
            let id = arguments.last, let session = UUID(uuidString: id)
        else {
            fputs("Usage: Vorsmate --computer-use-panel begin|end SESSION_UUID\n", stderr)
            exit(2)
        }
        guard let bundleID = Bundle.main.bundleIdentifier else {
            fputs("Run the command using the Vorsmate.app executable.\n", stderr)
            exit(2)
        }
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let pid = ProcessInfo.processInfo.processIdentifier
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.processIdentifier != pid && $0.bundleURL?.resolvingSymlinksInPath().path == bundlePath
        }
        guard matches.count == 1, let target = matches.first else {
            fputs("Expected one running instance of this Vorsmate.app.\n", stderr)
            exit(1)
        }
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: String(target.processIdentifier),
            userInfo: ["action": action.rawValue, "session": session.uuidString], deliverImmediately: true)
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notification, object: String(ProcessInfo.processInfo.processIdentifier), queue: .main
        ) { [weak self] notification in
            guard let name = notification.userInfo?["action"] as? String, let action = Action(rawValue: name),
                let id = notification.userInfo?["session"] as? String, let session = UUID(uuidString: id)
            else { return }
            MainActor.assumeIsolated { self?.receive(action, session: session) }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        reset()
    }

    func reset() {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard session != nil else { return }
        session = nil
        onChange()
    }

    private func receive(_ action: Action, session: UUID) {
        switch action {
        case .begin:
            self.session = session
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: Self.timeout) } catch { return }
                guard !Task.isCancelled else { return }
                self?.reset()
            }
            onChange()
        case .end:
            if self.session == session { reset() }
        }
    }
}
