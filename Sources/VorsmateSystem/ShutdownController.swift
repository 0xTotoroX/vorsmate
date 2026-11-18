// [INPUT]: ShutdownDriver、ShutdownPolicy、可注入的异步等待与保存回调。
// [OUTPUT]: 五秒倒计时、取消、跳过列表、清理与一次性系统动作及模拟反馈。
// [POS]: 主线程一键下班运行时；隐藏 / 停用取消未提交动作，不访问真实驱动之外的系统。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import VorsmateCore

@MainActor
public final class ShutdownController: ObservableObject {
    @Published public private(set) var policy: ShutdownPolicy
    @Published public private(set) var apps: [RunningAppItem] = []
    @Published public private(set) var countdown: Int?
    @Published public private(set) var pendingAction: ShutdownAction?
    @Published public private(set) var executing = false
    @Published public private(set) var message: String?
    @Published public private(set) var error: String?
    private let driver: any ShutdownDriver
    private let persist: (ShutdownPolicy) throws -> Void
    private let sleep: (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var active = false
    private var visible = false
    private var submitted = false
    private var observers: [NSObjectProtocol] = []
    public static let countdownSeconds = 5
    public var isPreview: Bool { driver.isPreview }
    public var appCount: Int { apps.filter { !policy.excludedBundleIDs.contains($0.id) }.count }
    public var status: String {
        if executing { return "正在清理" }
        if let countdown, let pendingAction { return "\(countdown) 秒后\(pendingAction.title)" }
        return "就绪"
    }
    public init(
        driver: any ShutdownDriver, policy: ShutdownPolicy = .init(),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        persist: @escaping (ShutdownPolicy) throws -> Void = { _ in }
    ) {
        self.driver = driver
        self.policy = policy
        self.sleep = sleep
        self.persist = persist
    }
    public func reloadPolicy(_ policy: ShutdownPolicy) {
        cancel()
        self.policy = policy
    }
    public func activate() {
        guard !active else { return }
        active = true
        refresh()
        guard !driver.isPreview else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in Task { @MainActor in self?.refresh() }
                })
        }
    }
    public func deactivate() {
        active = false
        cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }
    public func panelDidChangeVisibility(_ visible: Bool) {
        self.visible = visible
        if !visible { cancel() } else { refresh() }
    }
    public func refresh() {
        if active && countdown == nil && !executing { apps = driver.runningApps() }
    }
    public func updatePolicy(_ next: ShutdownPolicy) {
        guard !executing, countdown == nil else { return }
        do {
            try persist(next)
            policy = next
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    public func toggleExcluded(_ id: String) {
        setIncluded(policy.excludedBundleIDs.contains(id), ids: [id])
    }
    public func setIncluded(_ included: Bool, ids: Set<String>) {
        var next = policy
        if included { next.excludedBundleIDs.subtract(ids) } else { next.excludedBundleIDs.formUnion(ids) }
        if next != policy { updatePolicy(next) }
    }
    public func start(_ action: ShutdownAction) {
        guard active, visible, countdown == nil, !executing else { return }
        message = nil
        error = nil
        pendingAction = action
        countdown = Self.countdownSeconds
        let policy = self.policy
        let planned = apps.filter { !policy.excludedBundleIDs.contains($0.id) }
        let token = generation
        task = Task { [weak self, sleep] in
            do {
                for remaining in stride(from: Self.countdownSeconds - 1, through: 0, by: -1) {
                    try await sleep(.seconds(1))
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    self.countdown = remaining
                }
                guard let self, self.generation == token else { return }
                self.countdown = nil
                self.executing = true
                // The driver checks the original PIDs and bundle identity again before each quit.
                let targets = planned.filter { self.driver.isRunning($0) }
                if policy.disableReopenWindows { try self.driver.disableReopenWindows() }
                for app in targets { self.driver.terminate(app, force: false) }
                if !targets.isEmpty { try await sleep(.milliseconds(1500)) }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let remaining = targets.filter { self.driver.isRunning($0) }
                if policy.forceCloseApps {
                    for app in remaining { self.driver.terminate(app, force: true) }
                } else if !remaining.isEmpty {
                    let names = remaining.prefix(2).map { "「" + $0.name + "」" }.joined(separator: "、")
                    let rest = remaining.count > 2 ? "等 \(remaining.count) 个应用" : ""
                    throw ShutdownFailure.message("\(names)\(rest)仍在运行，已停止\(action.title)。")
                }
                self.submitted = true
                try await self.driver.execute(action)
                guard self.generation == token else { return }
                self.message = self.driver.isPreview ? "已完成模拟\(action.title)" : "已提交\(action.title)请求"
            } catch is CancellationError {
                // 隐藏或停用已经同步清除了状态。
            } catch {
                guard let self, self.generation == token else { return }
                self.error = error.localizedDescription
            }
            guard let self, self.generation == token else { return }
            self.submitted = false
            self.countdown = nil
            self.pendingAction = nil
            self.executing = false
            self.task = nil
            self.refresh()
        }
    }
    public func cancel() {
        guard !submitted else { return }
        let wasPending = countdown != nil || executing
        generation &+= 1
        task?.cancel()
        task = nil
        countdown = nil
        pendingAction = nil
        executing = false
        if wasPending && visible { refresh() }
    }
}
