// [INPUT]: 可替换风扇驱动、已存档位、保存回调与工作区睡眠 / 唤醒事件。
// [OUTPUT]: 跨启动恢复、睡眠释放 / 唤醒恢复、空闲停轮询及控制确认状态。
// [POS]: 界面与助手的装配；串行请求和代次检查阻止迟到回读与停用后接管。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import VorsmateCore
import VorsmateFan

@MainActor
final class FanModel: ObservableObject {
    @Published private(set) var snapshot = FanSnapshot()
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var helperEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var controlConfirmed = true
    private(set) var savedProfiles: [Int: FanProfile]
    let preview: Bool
    let signed = FanServiceIdentity.teamID() != nil
    private let driver: any FanModelDriver
    private let persist: ([Int: FanProfile]) throws -> Void
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var operation: Task<Void, Never>?
    private var revision = 0
    private var active = false
    private var sleeping = false
    private var panelVisible = false
    var polling: Bool { timer != nil }
    var competingApp: String? { driver.competingApp }

    init(
        preview: Bool, savedProfiles: [Int: FanProfile] = [:],
        driver: (any FanModelDriver)? = nil,
        persist: @escaping ([Int: FanProfile]) throws -> Void = { _ in }
    ) {
        self.preview = preview
        self.savedProfiles = savedProfiles.filter { $0.value.mode != .system }
        self.persist = persist
        self.driver = driver ?? (preview ? PreviewFanModelDriver() : SystemFanModelDriver())
    }
    func reloadSavedProfiles(_ profiles: [Int: FanProfile]) {
        savedProfiles = profiles.filter { $0.value.mode != .system }
    }
    func activate() {
        guard !active else { return }
        active = true
        sleeping = false
        let center = NSWorkspace.shared.notificationCenter
        for (name, sleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        if sleep { self?.willSleep() } else { self?.didWake() }
                    }
                })
        }
        restoreSavedProfiles()
    }
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        updatePolling()
        if visible { refresh() }
    }
    private func updatePolling() {
        let needed = active && !sleeping && (panelVisible || !savedProfiles.isEmpty || !snapshot.profiles.isEmpty)
        if !needed {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let value = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(value, forMode: .common)
            timer = value
        }
    }
    private func authorization() {
        helperEnabled = driver.helperEnabled
        needsApproval = driver.needsApproval
    }
    // 所有请求串行：停止的 release 必须晚于在途 configure，新激活必须晚于 release。
    private func enqueue(_ action: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task {
            await previous?.value
            await action()
        }
    }
    func refresh() {
        guard active, !sleeping, !busy else { return }
        let wasEnabled = helperEnabled
        authorization()
        if !wasEnabled && helperEnabled {
            restoreSavedProfiles()
            return
        }
        busy = true
        let token = revision
        enqueue { [weak self] in
            guard let self, self.active, !self.sleeping, self.revision == token else { return }
            defer {
                if self.revision == token {
                    self.busy = false
                    self.updatePolling()
                }
            }
            do {
                if self.helperEnabled {
                    let state = try await self.driver.request(FanCommand(action: .status))
                    guard self.revision == token else { return }
                    self.snapshot = state
                    if self.competingApp != nil, !self.snapshot.profiles.isEmpty {
                        let released = try await self.driver.request(FanCommand(action: .release))
                        guard self.revision == token else { return }
                        self.snapshot = released
                        throw FanFailure.competingTool
                    }
                } else {
                    self.snapshot = try self.driver.read()
                }
                self.controlConfirmed = true
                self.error = nil
            } catch {
                guard self.revision == token else { return }
                self.error = error.localizedDescription
                self.controlConfirmed = !self.helperEnabled
                self.readLocal()
            }
        }
    }
    private func readLocal() {
        do {
            var reading = try driver.read()
            if helperEnabled {
                reading.profiles = snapshot.profiles
                reading.safetyPause = snapshot.safetyPause
            }
            snapshot = reading
        } catch { self.error = error.localizedDescription }
    }
    func configure(id: Int, profile: FanProfile) {
        guard active, !sleeping, !busy else { return }
        authorization()
        guard competingApp == nil else {
            error = FanFailure.competingTool.localizedDescription
            return
        }
        guard helperEnabled else {
            error = FanFailure.notAuthorized.localizedDescription
            return
        }
        var next = savedProfiles
        if profile.mode == .system { next.removeValue(forKey: id) } else { next[id] = profile }
        do { try persist(next) } catch {
            self.error = error.localizedDescription
            return
        }
        savedProfiles = next
        revision &+= 1
        let token = revision
        busy = true
        updatePolling()
        enqueue { [weak self] in
            guard let self, self.active, !self.sleeping, self.revision == token else { return }
            defer {
                if self.revision == token {
                    self.busy = false
                    self.updatePolling()
                }
            }
            do {
                let state = try await self.driver.request(FanCommand(action: .configure, fanID: id, profile: profile))
                guard self.revision == token else { return }
                self.snapshot = state
                self.controlConfirmed = true
                self.error = nil
            } catch {
                guard self.revision == token else { return }
                self.error = error.localizedDescription
                self.controlConfirmed = false
                if let state = try? await self.driver.request(FanCommand(action: .status)), self.revision == token {
                    self.snapshot = state
                    self.controlConfirmed = true
                }
            }
        }
    }
    private func restoreSavedProfiles() {
        guard active, !sleeping else { return }
        authorization()
        revision &+= 1
        let token = revision
        let profiles = savedProfiles
        controlConfirmed = !helperEnabled
        busy = true
        updatePolling()
        enqueue { [weak self] in
            guard let self, self.active, !self.sleeping, self.revision == token else { return }
            defer {
                if self.revision == token {
                    self.busy = false
                    self.updatePolling()
                }
            }
            do {
                var failures: [String] = []
                if self.helperEnabled {
                    guard self.competingApp == nil else { throw FanFailure.competingTool }
                    for id in profiles.keys.sorted() {
                        guard self.active, !self.sleeping, self.revision == token else { return }
                        do {
                            _ = try await self.driver.request(
                                FanCommand(action: .configure, fanID: id, profile: profiles[id]))
                        } catch { failures.append("风扇 \(id + 1)：\(error.localizedDescription)") }
                    }
                    let state = try await self.driver.request(FanCommand(action: .status))
                    guard self.revision == token else { return }
                    self.snapshot = state
                } else {
                    self.snapshot = try self.driver.read()
                }
                self.controlConfirmed = true
                self.error = failures.isEmpty ? nil : failures.joined(separator: "；")
            } catch {
                guard self.revision == token else { return }
                self.error = error.localizedDescription
                self.controlConfirmed = false
                self.readLocal()
            }
        }
    }
    func willSleep() {
        guard active, !sleeping else { return }
        sleeping = true
        release()
        updatePolling()
    }
    func didWake() {
        guard active, sleeping else { return }
        sleeping = false
        restoreSavedProfiles()
    }
    func release() {
        revision &+= 1
        let token = revision
        controlConfirmed = !driver.helperEnabled
        busy = false
        enqueue { [weak self] in
            guard let self else { return }
            do {
                if self.driver.helperEnabled {
                    let state = try await self.driver.request(FanCommand(action: .release))
                    if self.revision == token {
                        self.snapshot = state
                        self.controlConfirmed = true
                    }
                }
            } catch { if self.revision == token { self.error = error.localizedDescription } }
            self.driver.invalidate()
        }
    }
    func stop() {
        guard active else { return }
        active = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        release()
        updatePolling()
    }
    func installHelper() {
        do {
            try driver.install()
            restoreSavedProfiles()
        } catch { self.error = error.localizedDescription }
    }
    func uninstallHelper() {
        guard !preview, !busy else { return }
        revision &+= 1
        let token = revision
        busy = true
        enqueue { [weak self] in
            guard let self else { return }
            defer { if self.revision == token { self.busy = false } }
            do {
                if self.driver.helperEnabled { _ = try await self.driver.request(FanCommand(action: .release)) }
                try await self.driver.uninstall()
                self.driver.invalidate()
                self.authorization()
                self.readLocal()
                self.error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    // 测试等待模型队列，不调用真实硬件。
    func waitForOperations() async { await operation?.value }
}
