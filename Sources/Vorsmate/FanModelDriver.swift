// [INPUT]: 签名 XPC、SMAppService、SMC 与内存风扇运行时。
// [OUTPUT]: 可替换的风扇模型驱动；真实授权入口与无硬件预览。
// [POS]: FanModel 的系统边界，测试不创建真实 SMC 或 XPC 连接。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ServiceManagement
import VorsmateCore
import VorsmateFan

@MainActor
protocol FanModelDriver: AnyObject {
    var helperEnabled: Bool { get }
    var needsApproval: Bool { get }
    var competingApp: String? { get }
    func read() throws -> FanSnapshot
    func request(_ command: FanCommand) async throws -> FanSnapshot
    func invalidate()
    func install() throws
    func uninstall() async throws
}

@MainActor
final class SystemFanModelDriver: FanModelDriver {
    private let hardware = SMCFanDriver()
    private let client = FanConnection()
    private let service = SMAppService.daemon(plistName: FanServiceIdentity.plist)
    var helperEnabled: Bool { service.status == .enabled }
    var needsApproval: Bool { service.status == .requiresApproval }
    var competingApp: String? {
        let names = [
            "com.crystalidea.macsfancontrol": "Macs Fan Control", "com.tunabellysoftware.TG-Pro": "TG Pro",
            "com.eidac.smcFanControl2": "smcFanControl",
        ]
        return NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.flatMap { names[$0] } }.first
    }
    func read() throws -> FanSnapshot { try hardware.read() }
    func request(_ command: FanCommand) async throws -> FanSnapshot { try await client.request(command) }
    func invalidate() { client.invalidate() }
    func install() throws {
        guard FanServiceIdentity.teamID() != nil else {
            throw FanFailure.remote("此构建仅支持监控；请使用 Apple 开发签名构建后启用调速。")
        }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            throw FanFailure.remote("请先把 Vorsmate 放入“应用程序”文件夹，再启用调速。")
        }
        if needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            do { try service.register() } catch { if !needsApproval { throw error } }
            if needsApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }
    func uninstall() async throws { try await service.unregister() }
}

@MainActor
final class PreviewFanModelDriver: FanModelDriver {
    let helperEnabled = true
    let needsApproval = false
    let competingApp: String? = nil
    private let hardware = PreviewFanHardware()
    private lazy var runtime = FanRuntime(hardware: hardware)
    func read() throws -> FanSnapshot { try hardware.read() }
    func request(_ command: FanCommand) async throws -> FanSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        switch command.action {
        case .configure:
            if let id = command.fanID, let profile = command.profile {
                try runtime.configure(fanID: id, profile: profile, at: now)
            }
        case .release: runtime.releaseAll()
        case .status:
            runtime.renew(at: now)
            runtime.tick(at: now)
        case .shutdown, .restart: throw FanFailure.notAuthorized
        }
        return try runtime.snapshot()
    }
    func invalidate() { runtime.releaseAll() }
    func install() throws {}
    func uninstall() async throws {}
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
