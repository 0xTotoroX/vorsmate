// [INPUT]: 内置与可选资源计数插件、AppModel、PanelView 与临时配置存储。
// [OUTPUT]: 全组合顺序、幂等启停、持久化失败、禁用不刷新、时间对照按序分组与跨分类指示点响应式刷新测试。
// [POS]: 内置宿主生命周期与主面板组织回归，不调用设备 API。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import Foundation
import Testing
import VorsmateCore

@testable import Vorsmate

@Suite("插件宿主")
@MainActor
struct PluginHostTests {
    // 逐一提交各组合，避免成千上万个主线程测试同时排队，阻塞其他插件的异步回调。
    @Test("任意组合保留顺序且关闭立即释放资源", .serialized, arguments: 0..<(1 << PluginID.allCases.count))
    func combinations(mask: Int) throws {
        let probes = PluginID.allCases.map { PluginProbe(id: $0) }
        var saved: Set<PluginID> = []
        let host = PluginHost(plugins: probes, disabled: []) { saved = $0 }
        host.start()
        host.start()
        host.panelDidChangeVisibility(true)
        for (index, id) in PluginID.allCases.enumerated() where mask & (1 << index) != 0 {
            try host.setEnabled(false, for: id)
            try host.setEnabled(false, for: id)
        }
        host.refresh()
        let expected = PluginID.allCases.enumerated().filter { mask & (1 << $0.offset) == 0 }.map(\.element)
        #expect(host.enabledIDs == expected)
        #expect(saved == Set(PluginID.allCases).subtracting(expected))
        for probe in probes {
            #expect(probe.starts == 1)
            #expect(probe.stops == (expected.contains(probe.id) ? 0 : 1))
            #expect(probe.refreshes == (expected.contains(probe.id) ? 1 : 0))
            #expect(probe.visible == expected.contains(probe.id))
        }
        host.stop()
        host.stop()
        #expect(probes.allSatisfy { $0.stops == 1 })
        host.start()
        #expect(probes.allSatisfy { $0.starts == (expected.contains($0.id) ? 2 : 1) })
        host.stop()
    }
    @Test("失败保存不停止插件；成功设置跨实例生效")
    func persistence() throws {
        let probe = PluginProbe(id: .fan)
        let bad = PluginHost(plugins: [probe], disabled: []) { _ in throw CocoaError(.fileWriteUnknown) }
        bad.start()
        #expect(throws: (any Error).self) { try bad.setEnabled(false, for: .fan) }
        #expect(probe.stops == 0)
        bad.stop()
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreferencesStore(url: folder.appending(path: "settings.json"))
        let host = PluginHost(plugins: [], disabled: []) { disabled in
            var preferences = Preferences()
            preferences.disabledPlugins = disabled
            try store.save(preferences)
        }
        try host.setEnabled(false, for: .fan)
        let restored = PluginHost(plugins: [probe], disabled: try store.load().disabledPlugins) { _ in }
        restored.start()
        #expect(probe.starts == 1)
        try restored.setEnabled(true, for: .fan)
        #expect(probe.starts == 2)
        restored.stop()
    }

    @Test("窗口拖动默认关闭，内存预览可改键、停用并重新启用")
    func windowDragLifecycle() {
        let model = AppModel(previewOptions: PreviewOptions(arguments: ["--preview"]))
        defer { model.stop() }
        #expect(!model.enabledPlugins.contains(.windowDrag))
        #expect(model.windowDrag.status == .inactive)
        model.setPlugin(.windowDrag, enabled: true)
        #expect(model.windowDrag.status == .ready)
        model.setWindowDragModifier(.commandOption)
        model.setPlugin(.windowDrag, enabled: false)
        model.refresh()
        #expect(model.windowDrag.status == .inactive)
        model.setPlugin(.windowDrag, enabled: true)
        #expect(model.windowDrag.modifier == .commandOption)
        #expect(model.windowDrag.status == .ready)
    }

    @Test("待办预览只在明确预览时启用，并打开信息页的待办详情")
    func tasksPreviewRequiresExplicitPreviewMode() {
        let detail = "--preview-tasks-detail"
        let regular = PreviewOptions(arguments: [detail, "--preview-dark", "--preview-popover"])
        var prefs = Preferences()
        regular.apply(to: &prefs)
        #expect(!regular.enabled && !regular.dark && !regular.popover)
        #expect(regular.initialCategory == nil && regular.initialSection == nil)
        #expect(!prefs.tasksEnabled)

        let preview = PreviewOptions(arguments: ["--preview", detail])
        preview.apply(to: &prefs)
        #expect(preview.initialCategory == .information && preview.initialSection == .tasks)
        #expect(prefs.tasksEnabled)
    }

    @Test("时间对照模块严格按 pluginOrder 排位分卡，不强行置顶")
    func timeComparisonCardOrderFollowsPluginOrder() {
        let timeFirst = PanelView.cardGroups(for: [.time, .inputSource, .fan])
        #expect(timeFirst == [.time, .list([.inputSource, .fan])])

        let timeMiddle = PanelView.cardGroups(for: [.inputSource, .time, .audioInput, .fan])
        #expect(timeMiddle == [.list([.inputSource]), .time, .list([.audioInput, .fan])])

        let timeLast = PanelView.cardGroups(for: [.inputSource, .fan, .time])
        #expect(timeLast == [.list([.inputSource, .fan]), .time])
    }

    @Test("子模型状态变更时 AppModel 转发 objectWillChange 以刷新跨分类指示点")
    func appModelForwardsChildObjectWillChangeForCategoryIndicators() async {
        let model = AppModel(previewOptions: PreviewOptions(arguments: ["--preview"]))
        var changes = 0
        let cancellable = model.objectWillChange.sink { _ in
            changes += 1
        }
        defer {
            cancellable.cancel()
            model.stop()
        }

        let before = changes
        model.setPlugin(.translate, enabled: true)
        #expect(model.categoryIndicator(for: .tools) == .none)

        model.translation.saveAPIKey("")
        #expect(changes > before)
        #expect(model.categoryIndicator(for: .tools) == .error)

        let afterError = changes
        model.shutdown.start(.shutdown)
        #expect(changes > afterError)
        #expect(model.categoryIndicator(for: .system) == .active)
        model.shutdown.cancel()
    }
}

@MainActor
private final class PluginProbe: VorsmatePlugin {
    let id: PluginID
    var starts = 0
    var stops = 0
    var refreshes = 0
    var visible = false
    init(id: PluginID) { self.id = id }
    func activate() { starts += 1 }
    func deactivate() { stops += 1 }
    func refresh() { refreshes += 1 }
    func panelDidChangeVisibility(_ visible: Bool) { self.visible = visible }
}
