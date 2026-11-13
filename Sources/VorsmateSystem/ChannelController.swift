// [INPUT]: SourceDriver、SelectionPolicy、SwitchBudget 与配置保存回调。
// [OUTPUT]: 可观察的当前状态、手动锁定、自动优先级、冷却复查与持续异常反馈。
// [POS]: 单个管理通道的运行时；主线程串行处理，切换异常退避重试，回读正常后自动恢复。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import Foundation
import OSLog
import VorsmateCore

@MainActor
public final class ChannelController: ObservableObject, Identifiable {
    public let channel: Channel
    public nonisolated var id: Channel { channel }
    @Published public private(set) var policy: SelectionPolicy
    @Published public private(set) var snapshot = Snapshot()
    @Published public private(set) var error: String?
    @Published public private(set) var suspended = false
    @Published public private(set) var recovering = false
    @Published public private(set) var pending = false
    private let driver: any SourceDriver
    private let persist: (SelectionPolicy) throws -> Void
    private let clock: () -> TimeInterval
    private var budget = SwitchBudget()
    private var watching = false
    private var timer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?
    private var observationGeneration = 0
    private var pendingPolicy: SelectionPolicy?
    private var persistenceError: String?
    private let logger = Logger(subsystem: "app.vorsmate.mac", category: "Selection")
    private var recovery: Recovery?

    private struct Recovery {
        static let warningDelay: TimeInterval = 30
        let beganAt: TimeInterval
        var retryAt: TimeInterval
        private var delay: TimeInterval = 5

        init(at time: TimeInterval) {
            beganAt = time
            retryAt = time + delay
        }

        mutating func deferAttempt(from time: TimeInterval) {
            delay = min(delay * 2, 30)
            retryAt = time + delay
        }
    }

    public init(
        channel: Channel, driver: any SourceDriver, policy: SelectionPolicy = .init(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        persist: @escaping (SelectionPolicy) throws -> Void = { _ in }
    ) {
        self.channel = channel
        self.driver = driver
        self.policy = policy
        self.clock = clock
        self.persist = persist
    }

    public var mode: String { !policy.enabled ? "off" : policy.lockedID == nil ? "auto" : "locked" }
    public var waitingName: String? {
        guard policy.isWaiting(in: snapshot) else { return nil }
        return policy.priority.first { $0.id == policy.lockedID }?.name ?? "锁定设备"
    }

    public func start() {
        updateWatching()
        refresh()
    }
    public func stop() {
        observationGeneration &+= 1
        timer?.invalidate()
        timer = nil
        debounceTask?.cancel()
        debounceTask = nil
        clearRecovery()
        pending = false
        driver.stop()
        watching = false
    }

    public func reload(_ policy: SelectionPolicy) {
        stop()
        self.policy = policy
        pendingPolicy = nil
        persistenceError = nil
        budget = SwitchBudget()
        suspended = false
        error = nil
        start()
    }

    public func setMode(_ mode: String) {
        change { policy in
            switch mode {
            case "off": policy.enabled = false
            case "auto": policy.automate()
            case "locked":
                let actual = try driver.read()
                snapshot = actual
                guard let id = actual.selectedID, actual.sources.contains(where: { $0.id == id }) else {
                    throw SystemFailure.unavailable
                }
                policy.discover(actual)
                policy.lock(id)
            default: return
            }
        }
    }
    public func select(_ id: String) {
        guard snapshot.sources.contains(where: { $0.id == id }) else {
            error = SystemFailure.unavailable.localizedDescription
            return
        }
        change { $0.lock(id) }
    }
    public func move(_ id: String, by offset: Int) { change { $0.move(id, by: offset) } }
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var next = policy
        next.move(fromOffsets: offsets, toOffset: destination)
        guard next != policy else { return }
        change { $0 = next }
    }
    public func forget(_ id: String) {
        guard !snapshot.sources.contains(where: { $0.id == id }), policy.lockedID != id else { return }
        change { $0.priority.removeAll { $0.id == id } }
    }
    public func retry() {
        if let pendingPolicy {
            change { $0 = pendingPolicy }
            return
        }
        budget = SwitchBudget()
        suspended = false
        clearRecovery()
        error = nil
        updateWatching()
        refresh()
    }

    private func change(_ mutation: (inout SelectionPolicy) throws -> Void) {
        var next = policy
        pendingPolicy = nil
        persistenceError = nil
        do { try mutation(&next) } catch {
            self.error = error.localizedDescription
            return
        }
        do {
            try persist(next)
            pendingPolicy = nil
            persistenceError = nil
            policy = next
            budget = SwitchBudget()
            suspended = false
            clearRecovery()
            error = nil
            updateWatching()
            refresh()
        } catch {
            pendingPolicy = next
            persistenceError = error.localizedDescription
            self.error = persistenceError
        }
    }

    private func updateWatching() {
        guard policy.enabled, !suspended else {
            stop()
            return
        }
        guard !watching else { return }
        do {
            let generation = observationGeneration
            try driver.start { [weak self] in
                guard let self, self.watching, self.observationGeneration == generation else { return }
                self.scheduleRefresh()
            }
            watching = true
            // 蓝牙通知可能遗漏，低频回读只在管理开启时运行。
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.watching, self.observationGeneration == generation else { return }
                    self.refresh()
                }
            }
        } catch {
            self.error = error.localizedDescription
            suspended = true
            stop()
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.refresh()
        }
    }

    private func scheduleVerification(after delay: Duration) {
        verificationTask?.cancel()
        let generation = observationGeneration
        verificationTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.observationGeneration == generation else { return }
            self.refresh()
        }
    }

    private func clearRecovery() {
        recovery = nil
        recovering = false
        verificationTask?.cancel()
        verificationTask = nil
    }

    private func updateRecoveryMessage(at time: TimeInterval) {
        if let persistenceError {
            error = persistenceError
        } else if let recovery, time - recovery.beganAt >= Recovery.warningDelay {
            error = "\(channel.title)管理持续异常，正在自动重试。"
        } else {
            error = nil
        }
    }

    private func waitForRecovery(at time: TimeInterval) {
        if recovery == nil {
            recovery = Recovery(at: time)
            logger.notice("\(self.channel.rawValue, privacy: .public): cooling down before retrying")
        }
        recovering = true
        pending = false
        updateRecoveryMessage(at: time)
        if let recovery {
            scheduleVerification(after: .seconds(max(0, recovery.retryAt - time)))
        }
    }

    private func selectTarget(_ target: String) {
        pending = true
        do {
            try driver.select(target)
        } catch {
            pending = false
            logger.error("\(self.channel.rawValue, privacy: .public): selection failed: \(error.localizedDescription)")
        }
        updateRecoveryMessage(at: clock())
        // 写入返回成功不等于已生效；无通知也回读，恢复期间每轮只尝试一次。
        scheduleVerification(after: .milliseconds(300))
    }

    public func refresh(readOnly: Bool = false) {
        let actual: Snapshot
        do {
            actual = try driver.read()
        } catch {
            pending = false
            if readOnly || !policy.enabled || suspended {
                self.error = persistenceError ?? error.localizedDescription
            } else {
                logger.error("\(self.channel.rawValue, privacy: .public): read failed: \(error.localizedDescription)")
                let time = clock()
                if var recovery, time >= recovery.retryAt {
                    recovery.deferAttempt(from: time)
                    self.recovery = recovery
                }
                waitForRecovery(at: time)
            }
            return
        }
        if actual != snapshot { snapshot = actual }
        if readOnly { return }
        do {
            var discovered = policy
            discovered.discover(actual)
            if discovered != policy {
                try persist(discovered)
                policy = discovered
            }
        } catch {
            pending = false
            self.error = persistenceError ?? error.localizedDescription
            return
        }
        guard !suspended else { return }
        guard let target = policy.target(in: actual), target != actual.selectedID else {
            clearRecovery()
            pending = false
            error = persistenceError
            return
        }
        let time = clock()
        if var recovery {
            guard time >= recovery.retryAt else {
                waitForRecovery(at: time)
                return
            }
            recovery.deferAttempt(from: time)
            self.recovery = recovery
            selectTarget(target)
            return
        }
        switch budget.request(at: time) {
        case .wait:
            // 回读可能早于限频窗口；主动续约，不依赖下一次通知或三秒轮询。
            scheduleVerification(after: .milliseconds(800))
        case .suspend:
            // 只暂停写入；继续监听和回读，当前选择正常后即可恢复原策略。
            waitForRecovery(at: time)
        case .allow:
            selectTarget(target)
        }
    }
}
