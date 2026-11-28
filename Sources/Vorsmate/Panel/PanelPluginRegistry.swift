// [INPUT]: 应用已装配的模块、生命周期和模块本身的状态。
// [OUTPUT]: 同一份登记提供生命周期命令、观察信号和总览指示。
// [POS]: 面板应用的组合层；系统驱动与纯规则不依赖面板。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import VorsmateCore
import VorsmateSystem

enum PanelPluginIndicator: Int, Comparable {
    case none
    case active
    case error

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor
struct PanelPluginRegistration {
    let plugin: any VorsmatePlugin
    var changes: ObservableObjectPublisher?
    var indicator: () -> PanelPluginIndicator = { .none }
}

@MainActor
extension AppModel {
    func registerPanelPlugins() -> [PanelPluginRegistration] {
        let channelPlugins = controllers.map { controller in
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: controller.channel.pluginID, activate: { controller.start() },
                    deactivate: { controller.stop() }, refresh: { controller.refresh() }),
                changes: controller.objectWillChange,
                indicator: { controller.error == nil ? .none : .error })
        }
        let fan = fan
        let shutdown = shutdown
        let unattendedAuth = unattendedAuth
        let windowDrag = windowDrag
        let translation = translation
        let tasks = tasks

        return [PanelPluginRegistration(plugin: BuiltinPlugin(id: .time))] + channelPlugins + [
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .fan, activate: { fan.activate() }, deactivate: { fan.stop() },
                    refresh: { fan.refresh() }, visibility: { fan.setPanelVisible($0) }),
                changes: fan.objectWillChange,
                indicator: { fan.error != nil || fan.snapshot.safetyPause != nil ? .error : .none }),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .quickShutdown, activate: { shutdown.activate() }, deactivate: { shutdown.deactivate() },
                    refresh: { shutdown.refresh() }, visibility: { shutdown.panelDidChangeVisibility($0) }),
                changes: shutdown.objectWillChange,
                indicator: {
                    if shutdown.error != nil { return .error }
                    return shutdown.canCancel || shutdown.executing ? .active : .none
                }),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .unattendedAuth, activate: { unattendedAuth.activate() },
                    deactivate: { unattendedAuth.deactivate() },
                    refresh: { unattendedAuth.refresh() }, visibility: { unattendedAuth.panelDidChangeVisibility($0) }),
                changes: unattendedAuth.objectWillChange,
                indicator: {
                    if unattendedAuth.errorMessage != nil
                        || unattendedAuth.passwordInvalidated
                        || (unattendedAuth.isEnabled && !unattendedAuth.accessibilityTrusted)
                    {
                        return .error
                    }
                    return unattendedAuth.isEnabled ? .active : .none
                }),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .windowDrag, activate: { windowDrag.start() }, deactivate: { windowDrag.stop() },
                    refresh: { windowDrag.refresh() }),
                changes: windowDrag.objectWillChange,
                indicator: { windowDrag.status.needsAttention ? .error : .none }),
            PanelPluginRegistration(plugin: remote, changes: remote.objectWillChange),
            PanelPluginRegistration(
                plugin: translation, changes: translation.objectWillChange,
                indicator: {
                    if translation.hotKeyConflict != nil || translation.feedbackIsError { return .error }
                    return translation.busy || translation.translating || translation.ocrRunning ? .active : .none
                }),
            PanelPluginRegistration(
                plugin: tasks, changes: tasks.objectWillChange,
                indicator: {
                    if tasks.actionError != nil { return .error }
                    return tasks.loading || tasks.mutating ? .active : .none
                }),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(id: .weather, deactivate: { [weather] in weather.clear() })),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .markets,
                    deactivate: { [marketFeeds] in
                        for feed in marketFeeds.values { feed.clear() }
                    })),
        ]
    }
}

extension Channel {
    fileprivate var pluginID: PluginID {
        switch self {
        case .inputSource: .inputSource
        case .audioInput: .audioInput
        case .audioOutput: .audioOutput
        }
    }
}
