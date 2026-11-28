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
            #expect(
                value.disabledAtRuntime == [
                    .remote, .translate, .tasks, .weather, .markets, .windowDrag, .coverArchive, .openList,
                ])
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
        value.disabledAtRuntime.remove(.coverArchive)
        value.disabledAtRuntime.remove(.openList)
        #expect(value.coverArchiveEnabled && value.openListEnabled)
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
        #expect(
            value.disabledAtRuntime == [
                .fan, .remote, .translate, .tasks, .weather, .markets, .windowDrag, .coverArchive, .openList,
            ])
        value.disabledAtRuntime.remove(.remote)
        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(restored.remoteEnabled)
        #expect(!restored.translateEnabled)
        #expect(!restored.tasksEnabled)
        #expect(!restored.coverArchiveEnabled && !restored.openListEnabled)
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
            .translate, .tasks, .weather, .markets, .windowDrag, .coverArchive, .openList,
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
        #expect(PluginCategory.allCases == [.information, .tools, .system])
        #expect(PluginCategory.information.title == "信息")
        #expect(PluginCategory.information.symbol == "info.circle")
        #expect(PluginCategory(savedValue: "devices") == .system)
        #expect(PluginCategory(savedValue: "tools") == .tools)
        #expect(PluginCategory(savedValue: "unknown") == nil)
        #expect(PluginCategory.tools.title == "工具")
        #expect(PluginCategory.tools.symbol == "wrench.and.screwdriver")
        #expect(PluginCategory.system.title == "系统")
        #expect(PluginCategory.system.symbol == "gearshape")

        #expect(
            PluginCategory.information.orderedPlugins(in: PluginID.allCases) == [.time, .weather, .markets, .tasks])
        #expect(
            PluginCategory.tools.orderedPlugins(in: PluginID.allCases) == [
                .remote, .translate, .windowDrag, .coverArchive, .openList,
            ])
        #expect(
            PluginCategory.system.orderedPlugins(in: PluginID.allCases) == [
                .inputSource, .audioInput, .audioOutput, .fan, .quickShutdown, .unattendedAuth,
            ])

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

    @Test("旧排序与同类调序都将待办固定在信息页末尾")
    func informationOrder() {
        let category = PluginCategory.information
        var prefs = Preferences()
        prefs.pluginOrder = [.tasks, .markets, .fan, .time, .weather]
        let before = prefs.resolvedOrder(from: PluginID.allCases)
        #expect(category.orderedPlugins(in: before) == [.markets, .time, .weather, .tasks])
        #expect(prefs.reorderedPluginOrder(moving: .tasks, within: category, by: -1) == prefs.pluginOrder)
        #expect(prefs.reorderedPluginOrder(moving: .weather, within: category, by: 1) == prefs.pluginOrder)
        prefs.pluginOrder = prefs.reorderedPluginOrder(moving: .time, within: category, by: -1)
        let after = prefs.resolvedOrder(from: PluginID.allCases)
        #expect(category.orderedPlugins(in: after) == [.time, .markets, .weather, .tasks])
        #expect(PluginCategory.system.orderedPlugins(in: after) == PluginCategory.system.orderedPlugins(in: before))
        #expect(category.orderedPlugins(in: after.filter { $0 != .tasks }) == [.time, .markets, .weather])
    }

    @Test("调整可见工具时跳过暂不可用的遥控器")
    func toolOrderWithoutRemote() {
        let category = PluginCategory.tools
        let available = [PluginID.translate, .windowDrag]
        var prefs = Preferences()
        prefs.pluginOrder = [.translate, .remote, .windowDrag]
        let before = prefs.resolvedOrder(from: PluginID.allCases)
        prefs.pluginOrder = prefs.reorderedPluginOrder(
            moving: .translate, within: category, by: 1, available: available)
        #expect(category.orderedPlugins(in: prefs.resolvedOrder(from: available)) == [.windowDrag, .translate])
        #expect(prefs.pluginOrder.firstIndex(of: .remote) == before.firstIndex(of: .remote))
    }
}
