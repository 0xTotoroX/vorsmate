// [INPUT]: 系统驱动、PreferencesStore、SMAppService 与更新模型。
// [OUTPUT]: 插件装配、配置与开关、可见性分发、开发版与隔离预览和维护入口。
// [POS]: 应用组合入口；通过 PluginHost 控制各模块资源；关机执行选择已授权助手或系统回退。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import ServiceManagement
import VorsmateCore
import VorsmateFan
import VorsmateSystem

@MainActor
final class AppModel: ObservableObject {
    let preview: Bool
    let development: Bool
    let maintenance: Bool
    private let canUseFanHelper: Bool
    lazy var fan = FanModel(
        preview: preview, savedProfiles: preferences.fanProfiles,
        driver: preview ? nil : SystemFanModelDriver(canUseHelper: canUseFanHelper)
    ) { [weak self] profiles in
        try self?.save { $0.fanProfiles = profiles }
    }
    lazy var shutdown = ShutdownController(
        driver: preview
            ? PreviewShutdownDriver(longList: CommandLine.arguments.contains("--preview-long-list"))
            : SystemShutdownDriver(systemAction: { [canUseFanHelper] action in
                if canUseFanHelper && SMAppService.daemon(plistName: FanServiceIdentity.plist).status == .enabled {
                    let client = FanConnection()
                    defer { client.invalidate() }
                    // A lost reply does not mean the helper failed to submit the system request.
                    _ = try await client.request(FanCommand(action: action == .shutdown ? .shutdown : .restart))
                    return
                }
                try await SystemShutdownDriver.appleScript(action)
            }), policy: preferences.shutdownPolicy,
        persist: { [weak self] policy in try self?.save { $0.shutdownPolicy = policy } })
    lazy var remote = RemoteCompanion(preview: preview)
    lazy var typelessRecovery: TypelessRecoveryModel = {
        if preview {
            return .preview(
                remoteFault: CommandLine.arguments.contains("--preview-typeless-remote"),
                timesOut: CommandLine.arguments.contains("--preview-typeless-timeout"))
        }
        return TypelessRecoveryModel(
            read: { [weak self] in
                TypelessSystem.diagnose(
                    companionPresent: self?.remote.available == true,
                    companionEnabled: self?.enabledPlugins.contains(.remote) == true,
                    companionReady: self?.remote.status == "遥控器就绪")
            },
            save: TypelessSystem.save, target: TypelessSystem.restartTarget)
    }()
    lazy var plugins = PluginHost(plugins: builtinPlugins(), disabled: preferences.disabledAtRuntime) {
        [weak self] disabled in
        try self?.save { $0.disabledAtRuntime = disabled }
    }
    let updates: UpdateModel
    @Published var configurationError: String?
    @Published var loginEnabled = false
    @Published var loginMessage: String?
    @Published var panelVisible = false {
        didSet { plugins.panelDidChangeVisibility(panelVisible) }
    }
    @Published private var preferences = Preferences()
    private(set) var controllers: [ChannelController] = []
    private let store = PreferencesStore.standard
    private var canSave = true

    init(preview: Bool, development: Bool = false) {
        self.preview = preview
        self.development = development
        self.canUseFanHelper = !development || FanServiceIdentity.teamID() != nil
        self.maintenance = !preview && !development && CommandLine.arguments.contains("--maintenance")
        self.updates = UpdateModel(enabled: !preview && !development)
        if !preview {
            if !development { refreshLoginStatus() }
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
        if preview && CommandLine.arguments.contains("--preview-popover") { preferences.remoteEnabled = true }
        for channel in Channel.allCases {
            let driver: any SourceDriver = preview ? PreviewDriver(channel: channel) : Self.driver(for: channel)
            if channel == .audioInput, let input = driver as? AudioDeviceDriver {
                remote.voiceReadiness = { [weak input] in input?.setRemoteVoiceReady($0) }
            }
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
        if canSave { plugins.start() }
    }
    private func save(_ change: (inout Preferences) -> Void) throws {
        guard canSave else { throw CocoaError(.fileReadCorruptFile) }
        var next = preferences
        change(&next)
        if !preview { try store.save(next, replacing: preferences) }
        preferences = next
    }
    private func builtinPlugins() -> [any VorsmatePlugin] {
        var result: [any VorsmatePlugin] = [BuiltinPlugin(id: .time)]
        for controller in controllers {
            result.append(
                BuiltinPlugin(
                    id: PluginID(rawValue: controller.channel.rawValue)!, activate: { controller.start() },
                    deactivate: { controller.stop() }, refresh: { controller.refresh() }))
        }
        let fan = fan
        let shutdown = shutdown
        result.append(
            BuiltinPlugin(
                id: .fan, activate: { fan.activate() }, deactivate: { fan.stop() },
                refresh: { fan.refresh() }, visibility: { fan.setPanelVisible($0) }))
        result.append(
            BuiltinPlugin(
                id: .quickShutdown, activate: { shutdown.activate() },
                deactivate: { shutdown.deactivate() }, refresh: { shutdown.refresh() },
                visibility: { shutdown.panelDidChangeVisibility($0) }))
        result.append(remote)
        return result
    }
    var availablePlugins: [PluginID] { PluginID.allCases.filter { $0 != .remote || remote.available } }
    var enabledPlugins: [PluginID] { availablePlugins.filter { plugins.enabledIDs.contains($0) } }
    func setPlugin(_ id: PluginID, enabled: Bool) {
        do { try plugins.setEnabled(enabled, for: id) } catch { configurationError = error.localizedDescription }
    }
    static func driver(for channel: Channel) -> any SourceDriver {
        switch channel {
        case .inputSource: InputSourceDriver()
        case .audioInput: AudioDeviceDriver(input: true)
        case .audioOutput: AudioDeviceDriver(input: false)
        }
    }
    func refresh() {
        remote.discover()
        objectWillChange.send()
        if !preview && !development { refreshLoginStatus() }
        if !canSave {
            do {
                preferences = try store.load()
                canSave = true
                configurationError = nil
                for controller in controllers { controller.reload(preferences[controller.channel], start: false) }
                fan.reloadSavedProfiles(preferences.fanProfiles)
                shutdown.reloadPolicy(preferences.shutdownPolicy)
                plugins.reloadDisabled(preferences.disabledAtRuntime)
                plugins.start()
            } catch {
                configurationError = "无法读取配置：\(error.localizedDescription)"
            }
        } else {
            plugins.refresh()
        }
    }
    func stop() {
        updates.stop()
        plugins.stop()
    }
    func setLogin(_ enabled: Bool) {
        guard !development else { return }
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
        var names: [String]
        switch channel {
        case .inputSource: names = ["简体拼音", "ABC"]
        case .audioInput: names = ["USB 麦克风", "蓝牙耳机", "内置麦克风"]
        case .audioOutput: names = ["蓝牙耳机", "内置扬声器"]
        }
        if CommandLine.arguments.contains("--preview-long-list") {
            names += (1...6).map { "备用设备 \($0)" }
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
