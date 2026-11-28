// [INPUT]: PluginID、插件生命周期与可失败的禁用集合保存回调。
// [OUTPUT]: 固定顺序的内置注册表、幂等启停与可见性转发。
// [POS]: AppModel 的资源宿主；视图移除与后台停止使用同一开关。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import VorsmateCore

@MainActor
protocol VorsmatePlugin: AnyObject {
    var id: PluginID { get }
    func activate()
    func deactivate()
    func refresh()
    func panelDidChangeVisibility(_ visible: Bool)
}

@MainActor
final class PluginHost: ObservableObject {
    @Published private(set) var disabledPlugins: Set<PluginID>
    private let plugins: [PluginID: any VorsmatePlugin]
    private let persist: (Set<PluginID>) throws -> Void
    private var running = false
    private var visible = false
    var enabledIDs: [PluginID] { PluginID.allCases.filter { !disabledPlugins.contains($0) } }

    init(plugins: [any VorsmatePlugin], disabled: Set<PluginID>, persist: @escaping (Set<PluginID>) throws -> Void) {
        self.plugins = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        disabledPlugins = disabled
        self.persist = persist
    }
    func reloadDisabled(_ disabled: Set<PluginID>) {
        stop()
        disabledPlugins = disabled
    }
    func start() {
        guard !running else { return }
        running = true
        for id in enabledIDs {
            plugins[id]?.activate()
            plugins[id]?.panelDidChangeVisibility(visible)
        }
    }
    func setEnabled(_ enabled: Bool, for id: PluginID) throws {
        guard enabled == disabledPlugins.contains(id) else { return }
        var next = disabledPlugins
        if enabled { next.remove(id) } else { next.insert(id) }
        try persist(next)
        disabledPlugins = next
        guard running else { return }
        if enabled {
            plugins[id]?.activate()
            plugins[id]?.panelDidChangeVisibility(visible)
        } else {
            plugins[id]?.panelDidChangeVisibility(false)
            plugins[id]?.deactivate()
        }
    }
    func refresh() { for id in enabledIDs where running { plugins[id]?.refresh() } }
    func panelDidChangeVisibility(_ visible: Bool) {
        self.visible = visible
        for id in enabledIDs where running { plugins[id]?.panelDidChangeVisibility(visible) }
    }
    func stop() {
        guard running else { return }
        running = false
        for id in enabledIDs.reversed() { plugins[id]?.deactivate() }
    }
}

@MainActor
final class BuiltinPlugin: VorsmatePlugin {
    let id: PluginID
    private let start: () -> Void
    private let stop: () -> Void
    private let update: () -> Void
    private let visibility: (Bool) -> Void
    init(
        id: PluginID, activate: @escaping () -> Void = {}, deactivate: @escaping () -> Void = {},
        refresh: @escaping () -> Void = {}, visibility: @escaping (Bool) -> Void = { _ in }
    ) {
        self.id = id
        start = activate
        stop = deactivate
        update = refresh
        self.visibility = visibility
    }
    func activate() { start() }
    func deactivate() { stop() }
    func refresh() { update() }
    func panelDidChangeVisibility(_ visible: Bool) { visibility(visible) }
}
