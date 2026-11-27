// [INPUT]: 内存 JSON 与临时配置目录。
// [OUTPUT]: 旧版兼容、新字段往返与原子冲突保护回归。
// [POS]: 插件 / 风扇 / 关机配置测试，不读取用户 settings.json。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore

@Suite("扩展配置兼容")
struct PluginPreferencesTests {
    @Test("旧版 version 1 和空可选字段保持默认")
    func legacy() throws {
        for json in [#"{"version":1,"policies":{}}"#, #"{"version":1,"policies":{},"disabledPlugins":null}"#] {
            let value = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
            #expect(value == Preferences())
            #expect(!value.tasksEnabled)
            #expect(value.disabledAtRuntime == [.remote, .translate, .tasks, .weather, .markets, .windowDrag])
            #expect(value.weatherCity == nil)
        }
    }
    @Test("完整新配置原子保存、重新加载且冲突不覆盖")
    func roundtrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PreferencesStore(url: directory.appending(path: "settings.json"))
        let old = Preferences()
        try store.save(old)
        var value = old
        value.disabledPlugins = [.time, .audioOutput]
        value.remoteEnabled = true
        value.translateEnabled = true
        value.tasksEnabled = true
        value.disabledAtRuntime.remove(.windowDrag)
        value.windowDragModifier = .commandOption
        #expect(value.windowDragEnabled && !value.disabledPlugins.contains(.windowDrag))
        value.weatherEnabled = true
        value.marketsEnabled = true
        value.weatherCity = WeatherCity(name: "示例市", latitude: 46.5, longitude: 6.6)
        value.translation.engine = .openAICompatible
        value.translation.targetLanguage = .japanese
        value.fanProfiles = [0: FanProfile(mode: .fixed, rpm: 2800), 1: FanCurvePreset.balanced.profile]
        value.shutdownPolicy.excludedBundleIDs = ["test.notes"]
        value.shutdownPolicy.forceCloseApps = false
        value.unattendedAuth = UnattendedAuthPreferences(
            approvePrivacySettings: false,
            approveAppPermissions: false,
            approveCredentialAndAppAuth: true,
            approveExistingDialogs: false
        )
        value.pluginOrder = [.fan, .time, .translate]
        try store.save(value, replacing: old)
        #expect(try store.load() == value)
        #expect(throws: (any Error).self) { try store.save(old, replacing: old) }
        #expect(try store.load() == value)
        #expect(value.version == 1)
    }

    @Test("无人值守授权选项缺省字段默认全部自动批准")
    func unattendedAuthPreferencesDefaults() throws {
        let legacyJSON = #"{"version":1,"policies":{},"unattendedAuth":{}}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(legacyJSON.utf8))
        #expect(decoded.unattendedAuth == UnattendedAuthPreferences())
        #expect(decoded.unattendedAuth.approvePrivacySettings)
        #expect(decoded.unattendedAuth.approveAppPermissions)
        #expect(decoded.unattendedAuth.approveCredentialAndAppAuth)
        #expect(decoded.unattendedAuth.approveExistingDialogs)
        #expect(decoded.unattendedAuth.optionsSummaryText == "全部")
    }
    @Test("可选模块的开关独立保存，旧宿主仍能识别原来的禁用列表")
    func optionalPlugins() throws {
        var value = Preferences()
        value.disabledPlugins = [.fan]
        #expect(value.disabledAtRuntime == [.fan, .remote, .translate, .tasks, .weather, .markets, .windowDrag])
        value.disabledAtRuntime.remove(.remote)
        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(restored.remoteEnabled)
        #expect(!restored.translateEnabled)
        #expect(!restored.tasksEnabled)
        #expect(restored.disabledPlugins == [.fan])
        value.disabledAtRuntime.insert(.remote)
        value.disabledAtRuntime.remove(.translate)
        value.disabledAtRuntime.remove(.tasks)
        value.disabledAtRuntime.remove(.weather)
        #expect(value.weatherEnabled && !value.marketsEnabled)
        value.disabledAtRuntime.remove(.markets)
        #expect(value.marketsEnabled)
        #expect(!value.remoteEnabled)
        #expect(value.translateEnabled)
        #expect(value.tasksEnabled)
        #expect(value.disabledPlugins == [.fan])
    }
    @Test("可选模块排在内置模块之后")
    func order() {
        let expected: [PluginID] = [
            .time, .inputSource, .audioInput, .audioOutput, .fan, .quickShutdown, .unattendedAuth, .remote,
            .translate, .tasks, .weather, .markets, .windowDrag,
        ]
        #expect(PluginID.allCases == expected)
        #expect(PluginID.audioInput.channel == .audioInput)
        #expect(PluginID.quickShutdown.title == "一键关机")
        #expect(PluginID.quickShutdown.symbol == "sunset")
        #expect(PluginID.translate.title == "截图")
        #expect(PluginID.translate.symbol == "viewfinder")
        #expect(PluginID.tasks.title == "待办")
        #expect(PluginID.tasks.symbol == "checklist")
    }
    @Test("插件分类元数据与自定义排序规则")
    func categoriesAndPluginOrder() throws {
        #expect(PluginCategory.allCases == [.devices, .tools, .system])
        #expect(PluginCategory.devices.title == "设备")
        #expect(PluginCategory.devices.symbol == "slider.horizontal.3")
        #expect(PluginCategory.tools.title == "工具")
        #expect(PluginCategory.tools.symbol == "viewfinder")
        #expect(PluginCategory.system.title == "系统")
        #expect(PluginCategory.system.symbol == "gearshape")

        #expect(PluginID.time.defaultCategory == .devices)
        #expect(PluginID.inputSource.defaultCategory == .devices)
        #expect(PluginID.audioInput.defaultCategory == .devices)
        #expect(PluginID.audioOutput.defaultCategory == .devices)
        #expect(PluginID.fan.defaultCategory == .devices)
        #expect(PluginID.translate.defaultCategory == .tools)
        #expect(PluginID.remote.defaultCategory == .tools)
        #expect(PluginID.tasks.defaultCategory == .tools)
        #expect(PluginID.windowDrag.defaultCategory == .tools)
        #expect(PluginID.weather.defaultCategory == .tools)
        #expect(PluginID.markets.defaultCategory == .tools)
        #expect(PluginID.quickShutdown.defaultCategory == .system)
        #expect(PluginID.unattendedAuth.defaultCategory == .system)

        var prefs = Preferences()
        #expect(prefs.pluginOrder.isEmpty)
        #expect(prefs.resolvedOrder(from: [.time, .fan, .translate]) == [.time, .fan, .translate])

        prefs.pluginOrder = [.translate, .remote, .translate, .fan]
        #expect(prefs.resolvedOrder(from: [.time, .fan, .translate]) == [.translate, .fan, .time])

        let movedUp = Preferences.movedOrder([.time, .fan, .translate], moving: .fan, by: -1)
        #expect(movedUp == [.fan, .time, .translate])
        let movedDown = Preferences.movedOrder([.time, .fan, .translate], moving: .fan, by: 1)
        #expect(movedDown == [.time, .translate, .fan])
        let clampedStart = Preferences.movedOrder([.time, .fan, .translate], moving: .time, by: -3)
        #expect(clampedStart == [.time, .fan, .translate])
        let clampedEnd = Preferences.movedOrder([.time, .fan, .translate], moving: .translate, by: 5)
        #expect(clampedEnd == [.time, .fan, .translate])
        let unchangedMissing = Preferences.movedOrder([.time, .fan], moving: .remote, by: 1)
        #expect(unchangedMissing == [.time, .fan])
    }
}
