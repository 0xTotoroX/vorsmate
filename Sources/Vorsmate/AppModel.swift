// [INPUT]: 系统驱动、PreferencesStore、SMAppService。
// [OUTPUT]: 三通道应用模型、登录状态、面板可见性、隔离预览与显式维护入口标记。
// [POS]: 应用组合入口；原生界面仅通过此模型与 ChannelController 操作。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import ServiceManagement
import VorsmateCore
import VorsmateSystem

@MainActor
final class AppModel: ObservableObject {
    let preview: Bool
    let maintenance: Bool
    let fan: FanModel
    @Published var configurationError: String?
    @Published var loginEnabled = false
    @Published var loginMessage: String?
    @Published var panelVisible = false
    private(set) var controllers: [ChannelController] = []
    private var preferences = Preferences()
    private let store = PreferencesStore.standard
    private var canSave = true

    init(preview: Bool) {
        self.preview = preview
        self.maintenance = !preview && CommandLine.arguments.contains("--maintenance")
        self.fan = FanModel(preview: preview)
        if !preview {
            refreshLoginStatus()
            do { preferences = try store.load() } catch {
                configurationError = "无法读取配置：\(error.localizedDescription)"
                canSave = false
            }
        } else if CommandLine.arguments.contains("--preview-offline") {
            preferences[.audioInput] = SelectionPolicy(
                enabled: true,
                priority: [Source(id: "preview-offline", name: "DJI 无线麦克风接收器 · 桌面录音备用设备")],
                lockedID: "preview-offline"
            )
        }
        for channel in Channel.allCases {
            let driver: any SourceDriver = preview ? PreviewDriver(channel: channel) : Self.driver(for: channel)
            let controller = ChannelController(
                channel: channel, driver: driver, policy: preferences[channel],
                persist: { [weak self] policy in
                    guard let self else { return }
                    guard self.canSave else { throw CocoaError(.fileReadCorruptFile) }
                    var next = self.preferences
                    next[channel] = policy
                    if !self.preview { try self.store.save(next, replacing: self.preferences) }
                    self.preferences = next
                })
            controllers.append(controller)
        }
        for controller in controllers {
            if canSave { controller.start() } else { controller.refresh(readOnly: true) }
        }
    }
    static func driver(for channel: Channel) -> any SourceDriver {
        switch channel {
        case .inputSource: InputSourceDriver()
        case .audioInput: AudioDeviceDriver(input: true)
        case .audioOutput: AudioDeviceDriver(input: false)
        }
    }
    func refresh() {
        if !preview { refreshLoginStatus() }
        if !canSave {
            do {
                preferences = try store.load()
                canSave = true
                configurationError = nil
                for controller in controllers { controller.reload(preferences[controller.channel]) }
            } catch {
                configurationError = "无法读取配置：\(error.localizedDescription)"
                for controller in controllers { controller.refresh(readOnly: true) }
            }
        } else {
            for controller in controllers { controller.refresh() }
        }
        fan.refresh()
    }
    func stop() {
        for controller in controllers { controller.stop() }
        fan.stop()
    }
    func setLogin(_ enabled: Bool) {
        guard !preview else {
            loginEnabled = enabled
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch { loginMessage = error.localizedDescription }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
    }
    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginMessage = status == .requiresApproval ? "请在系统设置的登录项中允许 Vorsmate。" : nil
    }
}

@MainActor
private final class PreviewDriver: SourceDriver {
    private var snapshot: Snapshot
    init(channel: Channel) {
        let names: [String]
        switch channel {
        case .inputSource: names = ["简体拼音", "ABC"]
        case .audioInput: names = ["USB 麦克风", "蓝牙耳机", "内置麦克风"]
        case .audioOutput: names = ["蓝牙耳机", "内置扬声器"]
        }
        snapshot = Snapshot(
            sources: names.enumerated().map { Source(id: "preview-\($0.offset)", name: $0.element) },
            selectedID: "preview-0")
    }
    func read() throws -> Snapshot { snapshot }
    func select(_ id: String) throws { snapshot.selectedID = id }
    func start(onChange: @escaping @MainActor () -> Void) throws {}
    func stop() {}
}
