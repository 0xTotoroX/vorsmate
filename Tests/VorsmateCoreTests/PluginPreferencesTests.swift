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
            #expect(value.disabledAtRuntime == [.remote])
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
        value.fanProfiles = [0: FanProfile(mode: .fixed, rpm: 2800), 1: FanCurvePreset.balanced.profile]
        value.shutdownPolicy.excludedBundleIDs = ["test.notes"]
        value.shutdownPolicy.forceCloseApps = false
        try store.save(value, replacing: old)
        #expect(try store.load() == value)
        #expect(throws: (any Error).self) { try store.save(old, replacing: old) }
        #expect(try store.load() == value)
        #expect(value.version == 1)
    }
    @Test("遥控器的开关独立保存，旧宿主仍能识别原来的禁用列表")
    func optionalRemote() throws {
        var value = Preferences()
        value.disabledPlugins = [.fan]
        #expect(value.disabledAtRuntime == [.fan, .remote])
        value.disabledAtRuntime.remove(.remote)
        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(restored.remoteEnabled)
        #expect(restored.disabledPlugins == [.fan])
        value.disabledAtRuntime.insert(.remote)
        #expect(!value.remoteEnabled)
        #expect(value.disabledPlugins == [.fan])
    }
    @Test("可选模块排在内置模块之后")
    func order() {
        #expect(PluginID.allCases == [.time, .inputSource, .audioInput, .audioOutput, .fan, .quickShutdown, .remote])
        #expect(PluginID.audioInput.channel == .audioInput)
    }
}
