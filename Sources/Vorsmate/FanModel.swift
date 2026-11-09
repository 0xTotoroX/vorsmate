// [INPUT]: 只读 SMC、签名受限 XPC、SMAppService、风扇规则与工作区事件。
// [OUTPUT]: 风扇面板状态、命令失败后回读实际模式、菜单持续续期、助手启停与三种模式。
// [POS]: 界面与助手的装配；启动只读，睡眠 / 退出时释放控制。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import ServiceManagement
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
    let preview: Bool
    let signed = FanServiceIdentity.teamID() != nil
    private let hardware: any FanHardware
    private let client = FanConnection()
    private let service = SMAppService.daemon(plistName: FanServiceIdentity.plist)
    private var previewRuntime: FanRuntime?
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var requestInFlight = false
    private var controlRevision = 0

    init(preview: Bool) {
        self.preview = preview
        let driver: any FanHardware = preview ? PreviewFanHardware() : SMCFanDriver()
        hardware = driver
        if preview {
            previewRuntime = FanRuntime(hardware: driver)
            helperEnabled = true
        } else {
            helperEnabled = service.status == .enabled
            needsApproval = service.status == .requiresApproval
        }
        controlConfirmed = preview || !helperEnabled
        refresh()
        let refreshTimer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.release() }
        }
    }
    var competingApp: String? {
        guard !preview else { return nil }
        let names = [
            "com.crystalidea.macsfancontrol": "Macs Fan Control", "com.tunabellysoftware.TG-Pro": "TG Pro",
            "com.eidac.smcFanControl2": "smcFanControl",
        ]
        return NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.flatMap { names[$0] } }
            .first
    }
    func refresh() {
        guard !busy, !requestInFlight else { return }
        if !preview {
            helperEnabled = service.status == .enabled
            needsApproval = service.status == .requiresApproval
        }
        if let runtime = previewRuntime {
            let now = ProcessInfo.processInfo.systemUptime
            runtime.renew(at: now)
            runtime.tick(at: now)
            do { snapshot = try runtime.snapshot() } catch { self.error = error.localizedDescription }
        } else if helperEnabled {
            requestInFlight = true
            let revision = controlRevision
            Task {
                defer { requestInFlight = false }
                do {
                    let reading = try await client.request(FanCommand(action: .status))
                    // 旧的轮询结果不能覆盖用户刚提交的模式。
                    guard revision == controlRevision else { return }
                    snapshot = reading
                    controlConfirmed = true
                    if competingApp != nil, !snapshot.profiles.isEmpty {
                        snapshot = try await client.request(FanCommand(action: .release))
                        error = FanFailure.competingTool.localizedDescription
                    } else {
                        error = nil
                    }
                } catch {
                    guard revision == controlRevision else { return }
                    self.error = error.localizedDescription
                    controlConfirmed = false
                    readLocal()
                }
            }
        } else {
            readLocal()
        }
    }
    private func readLocal() {
        do {
            var reading = try hardware.read()
            if helperEnabled {
                // 只读 SMC 无法知道助手的智能选择，不能把缺省配置伪装成系统模式。
                reading.profiles = snapshot.profiles
                reading.safetyPause = snapshot.safetyPause
            } else {
                controlConfirmed = true
            }
            snapshot = reading
        } catch { self.error = error.localizedDescription }
    }
    func installHelper() {
        guard !preview else { return }
        guard signed else {
            error = "此构建仅支持监控；请使用 Apple 开发签名构建后启用调速。"
            return
        }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            error = "请先把 Vorsmate 放入“应用程序”文件夹，再启用调速。"
            return
        }
        do {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                try service.register()
            }
            needsApproval = service.status == .requiresApproval
            helperEnabled = service.status == .enabled
            if needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            // 首次注册可能以 EPERM 返回，但已进入系统待授权列表。
            needsApproval = service.status == .requiresApproval
            if needsApproval {
                self.error = nil
                SMAppService.openSystemSettingsLoginItems()
            } else {
                self.error = error.localizedDescription
            }
        }
    }
    func configure(id: Int, profile: FanProfile) {
        guard !busy else { return }
        if competingApp != nil {
            error = FanFailure.competingTool.localizedDescription
            return
        }
        if preview {
            do {
                try previewRuntime?.configure(fanID: id, profile: profile, at: ProcessInfo.processInfo.systemUptime)
                if let state = try previewRuntime?.snapshot() { snapshot = state }
                error = nil
            } catch { self.error = error.localizedDescription }
            return
        }
        guard helperEnabled else {
            error = FanFailure.notAuthorized.localizedDescription
            return
        }
        controlRevision += 1
        let revision = controlRevision
        busy = true
        Task {
            defer { busy = false }
            do {
                let reading = try await client.request(FanCommand(action: .configure, fanID: id, profile: profile))
                guard revision == controlRevision else { return }
                snapshot = reading
                controlConfirmed = true
                error = nil
            } catch {
                guard revision == controlRevision else { return }
                self.error = error.localizedDescription
                controlConfirmed = false
                if case FanFailure.connectionTimeout = error { return }
                // 拒绝新配置和执行后恢复都会返回错误；立即回读，避免继续显示过期模式。
                do {
                    let reading = try await client.request(FanCommand(action: .status))
                    guard revision == controlRevision else { return }
                    snapshot = reading
                    controlConfirmed = true
                } catch {
                    guard revision == controlRevision else { return }
                    readLocal()
                }
            }
        }
    }
    func uninstallHelper() {
        guard !preview, !busy else { return }
        controlRevision += 1
        busy = true
        Task {
            defer { busy = false }
            do {
                // 恢复未获助手确认时保留助手，不能取消最后的恢复路径。
                if service.status == .enabled {
                    snapshot = try await client.request(FanCommand(action: .release))
                }
                try await service.unregister()
                client.invalidate()
                helperEnabled = service.status == .enabled
                needsApproval = service.status == .requiresApproval
                error = nil
                readLocal()
            } catch { self.error = error.localizedDescription }
        }
    }
    func release() {
        if preview {
            previewRuntime?.releaseAll()
            refresh()
            return
        }
        guard helperEnabled else { return }
        controlRevision += 1
        Task {
            do { snapshot = try await client.request(FanCommand(action: .release)) } catch {
                self.error = error.localizedDescription
            }
            client.invalidate()
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        previewRuntime?.releaseAll()
        // 断开连接触发助手恢复；失联租约是第二条恢复路径。
        client.invalidate()
    }
}

@MainActor
private final class PreviewFanHardware: FanHardware {
    var fan = FanReading(id: 0, actualRPM: 1850, targetRPM: 1850, minimumRPM: 1000, maximumRPM: 4900, hardwareMode: 0)
    func read() throws -> FanSnapshot { FanSnapshot(fans: [fan], temperature: 96, controlTemperature: 82) }
    func setRPM(_ rpm: Double, fanID: Int) throws {
        fan.actualRPM = rpm
        fan.targetRPM = rpm
        fan.hardwareMode = 1
    }
    func restore(fanID: Int) throws {
        fan.actualRPM = 1850
        fan.targetRPM = 1850
        fan.hardwareMode = 0
    }
}
