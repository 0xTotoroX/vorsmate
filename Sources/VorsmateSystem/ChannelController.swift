// [INPUT]: SourceDriver、SelectionPolicy、SwitchBudget 与配置保存回调。
// [OUTPUT]: 可观察的当前状态、手动锁定、自动优先级、暂停与有界系统切换。
// [POS]: 单个管理通道的运行时；主线程串行处理，无通知时也有界回读和重试。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import Foundation
import VorsmateCore

@MainActor
public final class ChannelController: ObservableObject, Identifiable {
    public let channel: Channel
    public nonisolated var id: Channel { channel }
    @Published public private(set) var policy: SelectionPolicy
    @Published public private(set) var snapshot = Snapshot()
    @Published public private(set) var error: String?
    @Published public private(set) var suspended = false
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
        verificationTask?.cancel()
        verificationTask = nil
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
        verificationTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.refresh()
        }
    }

    public func refresh(readOnly: Bool = false) {
        do {
            let actual = try driver.read()
            if actual != snapshot { snapshot = actual }
            if readOnly { return }
            var discovered = policy
            discovered.discover(actual)
            if discovered != policy {
                try persist(discovered)
                policy = discovered
            }
            guard !suspended, let target = policy.target(in: actual) else {
                verificationTask?.cancel()
                verificationTask = nil
                if !suspended { error = persistenceError }
                pending = false
                return
            }
            guard target != actual.selectedID else {
                verificationTask?.cancel()
                verificationTask = nil
                pending = false
                error = persistenceError
                return
            }
            switch budget.request(at: clock()) {
            case .wait:
                // 回读可能早于限频窗口；主动续约，不能依赖下一次设备通知或三秒轮询。
                scheduleVerification(after: .milliseconds(800))
            case .suspend:
                suspended = true
                pending = false
                error = "多次切换仍未生效，已暂停。请检查设备或其他管理工具后重试。"
                stop()
            case .allow:
                pending = true
                // 写入成功并不等于生效；失败也有界重试，界面始终展示回读的真实选择。
                defer { scheduleVerification(after: .milliseconds(300)) }
                try driver.select(target)
            }
        } catch {
            pending = false
            self.error = persistenceError ?? error.localizedDescription
        }
    }
}
