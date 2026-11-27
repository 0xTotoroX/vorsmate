// [INPUT]: ShutdownDriver、ShutdownPolicy、可注入的异步等待与保存回调。
// [OUTPUT]: 菜单栏五秒倒计时、取消反馈、应用退出与有界回读和一次性系统动作的提交回执。
// [POS]: 主线程一键关机运行时；收起面板不取消倒计时，停用时取消未提交动作，不访问真实驱动之外的系统。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import OSLog
import VorsmateCore

@MainActor
public final class ShutdownController: ObservableObject {
    @Published public private(set) var policy: ShutdownPolicy
    @Published public private(set) var apps: [RunningAppItem] = []
    @Published public private(set) var countdown: Int?
    @Published public private(set) var pendingAction: ShutdownAction?
    @Published public private(set) var executing = false
    @Published public private(set) var submitting = false
    @Published public private(set) var message: String?
    @Published public private(set) var error: String?
    private let driver: any ShutdownDriver
    private let persist: (ShutdownPolicy) throws -> Void
    private let sleep: (Duration) async throws -> Void
    private let prepareSystemAction: (@MainActor () async throws -> Void)?
    private let recoverPreparedAction: (@MainActor () -> Void)?
    private let logger = Logger(subsystem: "app.vorsmate.mac", category: "Shutdown")
    private var task: Task<Void, Never>?
    private var generation = 0
    private var active = false
    private var visible = false
    private var observers: [NSObjectProtocol] = []
    public static let countdownSeconds = 5
    public static let forceExitPollAttempts = 20
    public var isPreview: Bool { driver.isPreview }
    public var appCount: Int { apps.filter { !policy.excludedBundleIDs.contains($0.id) }.count }
    public var canCancel: Bool { pendingAction != nil && !submitting }
    public var menuBarTitle: String? {
        ShutdownStatusFormatter.menuBarTitle(
            countdown: countdown, action: pendingAction, executing: executing, submitting: submitting)
    }
    public var status: String {
        if submitting, let pendingAction { return "正在提交\(pendingAction.title)请求" }
        if executing { return "正在退出应用" }
        if countdown != nil, let pendingAction { return "准备\(pendingAction.title)" }
        return "就绪"
    }
    public init(
        driver: any ShutdownDriver, policy: ShutdownPolicy = .init(),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        persist: @escaping (ShutdownPolicy) throws -> Void = { _ in },
        prepareSystemAction: (@MainActor () async throws -> Void)? = nil,
        recoverPreparedAction: (@MainActor () -> Void)? = nil
    ) {
        self.driver = driver
        self.policy = policy
        self.sleep = sleep
        self.persist = persist
        self.prepareSystemAction = prepareSystemAction
        self.recoverPreparedAction = recoverPreparedAction
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
        if visible { refresh() }
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
        guard active, countdown == nil, !executing else { return }
        message = nil
        error = nil
        pendingAction = action
        countdown = Self.countdownSeconds
        let policy = self.policy
        let planned = apps.filter { !policy.excludedBundleIDs.contains($0.id) }
        logger.info("\(action.rawValue, privacy: .public) countdown started; selected apps: \(planned.count)")
        let token = generation
        task = Task { [weak self, sleep] in
            do {
                for remaining in stride(from: Self.countdownSeconds - 1, through: 1, by: -1) {
                    try await sleep(.seconds(1))
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    self.countdown = remaining
                }
                try await sleep(.seconds(1))
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.countdown = nil
                self.executing = true
                // The driver checks the original PIDs and bundle identity again before each quit.
                let targets = planned.filter { self.driver.isRunning($0) }
                self.logger.info("Requesting app termination; active targets: \(targets.count)")
                for app in targets { self.driver.terminate(app, force: false) }
                if !targets.isEmpty { try await sleep(.milliseconds(1500)) }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                var remaining = targets.filter { self.driver.isRunning($0) }
                if !policy.forceCloseApps { try Self.requireExited(remaining, before: action, afterForce: false) }
                if policy.disableReopenWindows { try self.driver.disableReopenWindows() }
                for app in remaining { self.driver.terminate(app, force: true) }
                remaining.removeAll { !self.driver.isRunning($0) }
                // AppKit / SIGKILL 发出后进程可能还在内核回收，给原进程最多两秒完成退出。
                for _ in 0..<Self.forceExitPollAttempts where !remaining.isEmpty {
                    try await sleep(.milliseconds(100))
                    try Task.checkCancellation()
                    remaining.removeAll { !self.driver.isRunning($0) }
                }
                try Self.requireExited(remaining, before: action, afterForce: true)
                var didPrepare = false
                if let prepareSystemAction = self.prepareSystemAction {
                    didPrepare = true
                    do {
                        try await prepareSystemAction()
                        try Task.checkCancellation()
                        guard self.active, self.generation == token else {
                            throw CancellationError()
                        }
                    } catch {
                        self.recoverPreparedAction?()
                        throw error
                    }
                }
                self.submitting = true
                self.logger.info("Submitting \(action.rawValue, privacy: .public) request")
                do {
                    try await self.driver.execute(action)
                } catch {
                    if didPrepare {
                        self.recoverPreparedAction?()
                    }
                    throw error
                }
                guard self.generation == token else { return }
                self.message = self.driver.isPreview ? "已完成模拟\(action.title)" : "已提交\(action.title)请求"
                self.logger.info("Received submission acknowledgement for \(action.rawValue, privacy: .public)")
            } catch is CancellationError {
                // 隐藏或停用已经同步清除了状态。
            } catch {
                guard let self, self.generation == token else { return }
                self.error = error.localizedDescription
                self.logger.error("\(action.rawValue, privacy: .public) flow failed; submitting: \(self.submitting)")
            }
            guard let self, self.generation == token else { return }
            self.submitting = false
            self.countdown = nil
            self.pendingAction = nil
            self.executing = false
            self.task = nil
            self.refresh()
        }
    }
    private static func requireExited(_ apps: [RunningAppItem], before action: ShutdownAction, afterForce: Bool) throws
    {
        guard !apps.isEmpty else { return }
        let names = apps.prefix(2).map { "「" + $0.name + "」" }.joined(separator: "、")
        let rest = apps.count > 2 ? "等 \(apps.count) 个应用" : ""
        let stage = afterForce ? "强制退出后，" : ""
        throw ShutdownFailure.message("\(stage)\(names)\(rest)仍在运行，已停止\(action.title)。")
    }
    public func cancel() {
        guard !submitting else { return }
        let action = pendingAction
        generation &+= 1
        task?.cancel()
        task = nil
        countdown = nil
        pendingAction = nil
        executing = false
        if let action {
            message = "已取消\(action.title)"
            logger.info(
                "Cancelled \(action.rawValue, privacy: .public) before submission; panel visible: \(self.visible)")
            refresh()
        }
    }
}
