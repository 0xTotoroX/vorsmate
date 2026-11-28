// [INPUT]: 系统驱动、PreferencesStore、SMAppService 与更新模型。
// [OUTPUT]: 插件装配、配置与开关、可见性分发、开发版与隔离预览和维护入口。
// [POS]: 应用组合入口；通过 PluginHost 控制各模块资源；关机先释放已授权助手再走系统事件。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import ServiceManagement
import VorsmateCore
import VorsmateFan
import VorsmateSystem

@MainActor
final class AppModel: ObservableObject {
    let previewOptions: PreviewOptions
    var preview: Bool { previewOptions.enabled }
    let development: Bool
    let maintenance: Bool
    let canManageLogin: Bool
    private let canUseFanHelper: Bool
    lazy var fan = FanModel(
        preview: preview, savedProfiles: preferences.fanProfiles,
        driver: preview ? nil : SystemFanModelDriver(canUseHelper: canUseFanHelper)
    ) { [weak self] profiles in
        try self?.save { $0.fanProfiles = profiles }
    }
    lazy var shutdown = ShutdownController(
        driver: preview
            ? PreviewShutdownDriver(longList: previewOptions.longList)
            : SystemShutdownDriver(systemAction: SystemShutdownDriver.appleScript),
        policy: preferences.shutdownPolicy,
        persist: { [weak self] policy in try self?.save { $0.shutdownPolicy = policy } },
        prepareSystemAction: { [weak self] in
            guard let self else { return }
            if self.canUseFanHelper && SMAppService.daemon(plistName: FanServiceIdentity.plist).status == .enabled {
                try await self.fan.releaseForShutdown()
            }
        },
        recoverPreparedAction: { [weak self] in
            self?.fan.resumeAfterShutdownFailure()
        })
    lazy var unattendedAuth: UnattendedAuthController = {
        if preview {
            return UnattendedAuthController(
                driver: PreviewUnattendedAuthDriver(trusted: true),
                passwordStore: InMemoryUnattendedPasswordStore(
                    initialPassword: previewOptions.unattendedActive ? "preview-admin" : nil),
                passwordVerifier: FixedPasswordVerifier(),
                historyStore: .inMemory
            )
        }
        return UnattendedAuthController(
            driver: SystemUnattendedAuthDriver(),
            passwordStore: KeychainUnattendedPasswordStore(),
            passwordVerifier: OpenDirectoryPasswordVerifier(),
            historyStore: .standard,
            preferences: preferences.unattendedAuth,
            persist: { [weak self] prefs in
                try self?.save { $0.unattendedAuth = prefs }
            }
        )
    }()
    lazy var windowDrag = WindowDragMonitor(modifier: preferences.windowDragModifier, preview: preview)
    lazy var remote = RemoteCompanion(preview: preview)
    lazy var translation = TranslationModel(preview: preview, preferences: preferences.translation) {
        [weak self] prefs in
        try self?.save { $0.translation = prefs }
    }
    lazy var tasks = TasksModel(
        preview: preview,
        offlinePreview: previewOptions.offlineTasks
    )
    let informationClient: WeatherMarketClient
    let weather = PanelFeed<WeatherReading>(interval: .seconds(900))
    let marketFeeds = Dictionary(
        uniqueKeysWithValues: MarketInstrument.allCases.map { instrument in
            (instrument, PanelFeed<MarketQuote>(interval: .seconds(instrument == .dollarYuan ? 3600 : 300)))
        })
    var weatherCity: WeatherCity? { preferences.weatherCity }

    func selectWeatherCity(_ city: WeatherCity) {
        guard preferences.weatherCity != city else { return }
        do {
            try save { $0.weatherCity = city }
            weather.clear()
        } catch {
            configurationError = error.localizedDescription
        }
    }
    lazy var typelessRecovery: TypelessRecoveryModel = {
        if preview {
            return .preview(
                remoteFault: previewOptions.typelessRemote,
                timesOut: previewOptions.typelessTimeout)
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
    lazy var coverArchive = CoverArchiveModel(preview: preview)
    lazy var openList = preview ? OpenListModel.preview() : OpenListModel()
    private lazy var panelPlugins = Dictionary(
        uniqueKeysWithValues: registerPanelPlugins().map { ($0.plugin.id, $0) })
    lazy var plugins = PluginHost(plugins: panelPlugins.values.map(\.plugin), disabled: preferences.disabledAtRuntime) {
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
    private var childCancellables: [AnyCancellable] = []

    static func supportsLoginItem(bundle: Bundle = .main, preview: Bool) -> Bool {
        !preview && bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier == FanServiceIdentity.app
    }

    init(previewOptions: PreviewOptions, development: Bool = false) {
        self.previewOptions = previewOptions
        let preview = previewOptions.enabled
        self.development = development
        informationClient = preview ? .preview : WeatherMarketClient()
        self.canUseFanHelper = !development || FanServiceIdentity.teamID() != nil
        self.maintenance = !preview && !development && CommandLine.arguments.contains("--maintenance")
        self.canManageLogin = Self.supportsLoginItem(preview: preview)
        self.updates = UpdateModel(enabled: !preview && !development)
        if !preview {
            if canManageLogin { refreshLoginStatus() }
            do { preferences = try store.load() } catch {
                configurationError = "无法读取配置：\(error.localizedDescription)"
                canSave = false
            }
        } else {
            previewOptions.apply(to: &preferences)
        }
        for channel in Channel.allCases {
            let driver: any SourceDriver =
                preview
                ? PreviewDriver(channel: channel, longList: previewOptions.longList) : Self.driver(for: channel)
            if channel == .audioInput, let input = driver as? AudioDeviceDriver {
                remote.voiceReadiness = { [weak input] in input?.setRemoteVoiceReady($0) }
            }
            let controller = ChannelController(
                channel: channel, driver: driver, policy: preferences[channel],
                persist: { [weak self] policy in
                    try self?.save { $0[channel] = policy }
                })
            controllers.append(controller)
        }
        if canSave { plugins.start() }
        if previewOptions.unattendedActive {
            unattendedAuth.loadPreviewSampleHistory(now: unattendedAuth.now)
            _ = unattendedAuth.enable(deadlineChoice: previewOptions.unattendedDeadline ? .durationMinutes(25) : .none)
        }
        observeChildModels()
    }

    private func observeChildModels() {
        childCancellables.removeAll()
        let publishers =
            panelPlugins.values.compactMap(\.changes) + [
                typelessRecovery.objectWillChange, plugins.objectWillChange,
            ]
        for publisher in publishers {
            publisher.sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.objectWillChange.send()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.objectWillChange.send()
                    }
                }
            }
            .store(in: &childCancellables)
        }
    }
    private func save(_ change: (inout Preferences) -> Void) throws {
        guard canSave else { throw CocoaError(.fileReadCorruptFile) }
        var next = preferences
        change(&next)
        if !preview { try store.save(next, replacing: preferences) }
        preferences = next
    }
    func panelPlugin(_ id: PluginID) -> PanelPluginRegistration? { panelPlugins[id] }

    var availablePlugins: [PluginID] { PluginID.allCases.filter { panelPlugins[$0]?.available() == true } }
    var enabledPlugins: [PluginID] { availablePlugins.filter { plugins.enabledIDs.contains($0) } }
    var orderedAvailablePlugins: [PluginID] { preferences.resolvedOrder(from: availablePlugins) }
    var orderedEnabledPlugins: [PluginID] { preferences.resolvedOrder(from: enabledPlugins) }
    var hasCustomPluginOrder: Bool { !preferences.pluginOrder.isEmpty }

    func setPlugin(_ id: PluginID, enabled: Bool) {
        do { try plugins.setEnabled(enabled, for: id) } catch { configurationError = error.localizedDescription }
    }

    func setWindowDragModifier(_ modifier: WindowDragModifier) {
        guard modifier != windowDrag.modifier else { return }
        do {
            try save { $0.windowDragModifier = modifier }
            windowDrag.setModifier(modifier)
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func movePlugin(_ id: PluginID, in category: PluginCategory, by offset: Int) {
        let nextOrder = preferences.reorderedPluginOrder(
            moving: id, within: category, by: offset, available: availablePlugins)
        guard nextOrder != preferences.pluginOrder else { return }
        do {
            try save { $0.pluginOrder = nextOrder }
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func resetPluginOrder() {
        guard !preferences.pluginOrder.isEmpty else { return }
        do {
            try save { $0.pluginOrder = [] }
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func categoryIndicator(for category: PluginCategory) -> PanelPluginIndicator {
        let enabled = Set(enabledPlugins)
        return
            panelPlugins.values
            .filter { $0.plugin.id.defaultCategory == category && enabled.contains($0.plugin.id) }
            .map { $0.indicator() }
            .max() ?? .none
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
        if canManageLogin { refreshLoginStatus() }
        if !canSave {
            do {
                preferences = try store.load()
                canSave = true
                configurationError = nil
                for controller in controllers { controller.reload(preferences[controller.channel], start: false) }
                fan.reloadSavedProfiles(preferences.fanProfiles)
                shutdown.reloadPolicy(preferences.shutdownPolicy)
                unattendedAuth.reloadPreferences(preferences.unattendedAuth)
                translation.reloadPreferences(preferences.translation)
                windowDrag.setModifier(preferences.windowDragModifier)
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
        unattendedAuth.terminate()
        plugins.stop()
    }
    func setLogin(_ enabled: Bool) {
        guard !preview else {
            loginEnabled = enabled
            return
        }
        guard canManageLogin else { return }
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
    init(channel: Channel, longList: Bool) {
        var names: [String]
        switch channel {
        case .inputSource: names = ["简体拼音", "ABC"]
        case .audioInput: names = ["USB 麦克风", "蓝牙耳机", "内置麦克风"]
        case .audioOutput: names = ["蓝牙耳机", "内置扬声器"]
        }
        if longList {
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
