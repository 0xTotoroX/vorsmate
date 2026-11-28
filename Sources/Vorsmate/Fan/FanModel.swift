// [INPUT]: 可替换风扇驱动、已存档位、保存回调与工作区睡眠 / 唤醒事件。
// [OUTPUT]: 跨启动恢复、睡眠与关机前释放 / 唤醒或失败恢复、安静读数刷新及独立的手动处理状态。
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
    private var releasingForShutdown = false
    private var panelVisible = false
    private var refreshing = false
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
        releasingForShutdown = false
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
        let needed =
            active && !sleeping && !releasingForShutdown
            && (panelVisible || !savedProfiles.isEmpty || !snapshot.profiles.isEmpty)
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
        guard active, !sleeping, !releasingForShutdown, !busy, !refreshing else { return }
        let wasEnabled = helperEnabled
        authorization()
        if !wasEnabled && helperEnabled {
            restoreSavedProfiles()
            return
        }
        // 状态读取不占用界面的操作状态；在途读数去重，手动切档仍可排队。
        refreshing = true
        let token = revision
        enqueue { [weak self] in
            guard let self else { return }
            defer {
                self.refreshing = false
                self.updatePolling()
            }
            guard self.active, !self.sleeping, !self.releasingForShutdown, self.revision == token else { return }
            do {
                if self.helperEnabled {
                    let state = try await self.driver.request(FanCommand(action: .status))
                    guard self.revision == token, !self.releasingForShutdown else { return }
                    self.applySnapshot(state)
                    if self.competingApp != nil, !self.snapshot.profiles.isEmpty {
                        let released = try await self.driver.request(FanCommand(action: .release))
                        guard self.revision == token, !self.releasingForShutdown else { return }
                        self.applySnapshot(released)
                        throw FanFailure.competingTool
                    }
                } else {
                    self.snapshot = try self.driver.read()
                }
                self.controlConfirmed = true
                if self.error == nil || self.error == FanFailure.competingTool.localizedDescription {
                    self.error = nil
                }
            } catch {
                guard self.revision == token, !self.releasingForShutdown else { return }
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
                reading.safetyClearedFixedFanIDs = snapshot.safetyClearedFixedFanIDs
            }
            snapshot = reading
        } catch { self.error = error.localizedDescription }
    }
    func configure(id: Int, profile: FanProfile) {
        guard active, !sleeping, !releasingForShutdown, !busy else { return }
        authorization()
        guard competingApp == nil else {
            error = FanFailure.competingTool.localizedDescription
            return
        }
        guard helperEnabled else {
            error = FanFailure.notAuthorized.localizedDescription
            return
        }
        let previousSaved = savedProfiles
        var next = savedProfiles
        if profile.mode == .system { next.removeValue(forKey: id) } else { next[id] = profile }
        savedProfiles = next
        revision &+= 1
        let token = revision
        busy = true
        updatePolling()
        enqueue { [weak self] in
            guard let self, self.active, !self.sleeping, !self.releasingForShutdown, self.revision == token else {
                return
            }
            defer {
                if self.revision == token {
                    self.busy = false
                    self.updatePolling()
                }
            }
            do {
                let state = try await self.driver.request(FanCommand(action: .configure, fanID: id, profile: profile))
                guard self.revision == token, !self.releasingForShutdown else { return }
                var persistTarget = next
                for clearedID in state.safetyClearedFixedFanIDs where persistTarget[clearedID]?.mode == .fixed {
                    persistTarget.removeValue(forKey: clearedID)
                }
                self.savedProfiles = persistTarget
                self.snapshot = state
                do {
                    try self.persist(persistTarget)
                    self.controlConfirmed = true
                    self.error = nil
                } catch {
                    self.savedProfiles = previousSaved
                    self.error = error.localizedDescription
                    let rollbackProfile = previousSaved[id] ?? FanProfile()
                    if let rolledBack = try? await self.driver.request(
                        FanCommand(action: .configure, fanID: id, profile: rollbackProfile)),
                        self.revision == token
                    {
                        self.snapshot = rolledBack
                    }
                    self.controlConfirmed = true
                }
            } catch {
                guard self.revision == token, !self.releasingForShutdown else { return }
                self.savedProfiles = previousSaved
                self.error = error.localizedDescription
                self.controlConfirmed = false
                if let state = try? await self.driver.request(FanCommand(action: .status)),
                    self.revision == token, !self.releasingForShutdown
                {
                    self.applySnapshot(state)
                    self.controlConfirmed = true
                }
            }
        }
    }
    private func restoreSavedProfiles() {
        guard active, !sleeping, !releasingForShutdown else { return }
        authorization()
        revision &+= 1
        let token = revision
        let profiles = savedProfiles
        controlConfirmed = !helperEnabled
        busy = true
        updatePolling()
        enqueue { [weak self] in
            guard let self, self.active, !self.sleeping, !self.releasingForShutdown, self.revision == token else {
                return
            }
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
                        guard self.active, !self.sleeping, !self.releasingForShutdown, self.revision == token else {
                            return
                        }
                        do {
                            _ = try await self.driver.request(
                                FanCommand(action: .configure, fanID: id, profile: profiles[id]))
                        } catch { failures.append("风扇 \(id + 1)：\(error.localizedDescription)") }
                    }
                    let state = try await self.driver.request(FanCommand(action: .status))
                    guard self.revision == token, !self.releasingForShutdown else { return }
                    self.applySnapshot(state)
                } else {
                    self.snapshot = try self.driver.read()
                }
                self.controlConfirmed = true
                if !failures.isEmpty {
                    self.error = failures.joined(separator: "；")
                } else if self.error == nil || self.error == FanFailure.competingTool.localizedDescription {
                    self.error = nil
                }
            } catch {
                guard self.revision == token, !self.releasingForShutdown else { return }
                self.error = error.localizedDescription
                self.controlConfirmed = false
                self.readLocal()
            }
        }
    }
    private func applySnapshot(_ state: FanSnapshot) {
        snapshot = state
        let clearedIDs = state.safetyClearedFixedFanIDs.filter { savedProfiles[$0]?.mode == .fixed }
        guard !clearedIDs.isEmpty else { return }
        var updated = savedProfiles
        for id in clearedIDs {
            updated.removeValue(forKey: id)
        }
        savedProfiles = updated
        do {
            try persist(updated)
        } catch {
            self.error = error.localizedDescription
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
    func releaseForShutdown() async throws {
        releasingForShutdown = true
        timer?.invalidate()
        timer = nil
        revision &+= 1
        let token = revision
        busy = false
        await operation?.value
        authorization()
        guard driver.helperEnabled else { return }
        let state = try await driver.request(FanCommand(action: .release))
        if revision == token {
            snapshot = state
            controlConfirmed = true
            error = nil
        }
        driver.invalidate()
    }
    func resumeAfterShutdownFailure() {
        releasingForShutdown = false
        guard active && !sleeping else { return }
        restoreSavedProfiles()
    }
    func stop() {
        guard active else { return }
        active = false
        releasingForShutdown = false
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
