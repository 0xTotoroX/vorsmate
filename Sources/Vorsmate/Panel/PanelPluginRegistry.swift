// [INPUT]: 应用已装配的模块、生命周期和模块本身的状态。
// [OUTPUT]: 同一份登记提供启停、观察信号、可用性、分类指示和总览入口。
// [POS]: 面板应用的组合层；系统驱动与纯规则不依赖面板。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import SwiftUI
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
    struct RowContext {
        let expanded: Binding<Bool>
        let panelVisible: Bool
        let configurationAvailable: Bool
        let protectInteraction: (Bool) -> Void
        let openDetail: () -> Void
    }

    let plugin: any VorsmatePlugin
    let changes: ObservableObjectPublisher?
    let available: () -> Bool
    let indicator: () -> PanelPluginIndicator
    let row: (RowContext) -> AnyView

    init<Row: View>(
        plugin: any VorsmatePlugin, changes: ObservableObjectPublisher? = nil,
        available: @escaping () -> Bool = { true },
        indicator: @escaping () -> PanelPluginIndicator = { .none },
        @ViewBuilder row: @escaping (RowContext) -> Row
    ) {
        self.plugin = plugin
        self.changes = changes
        self.available = available
        self.indicator = indicator
        self.row = { context in AnyView(row(context)) }
    }
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
                indicator: { controller.error == nil ? .none : .error },
                row: { context in
                    ChannelView(controller: controller, expanded: context.expanded)
                        .disabled(!context.configurationAvailable)
                })
        }
        let fan = fan
        let shutdown = shutdown
        let unattendedAuth = unattendedAuth
        let windowDrag = windowDrag
        let translation = translation
        let tasks = tasks
        let enablesFanHelperInstallation = !development
        let remote = remote

        let time = PanelPluginRegistration(plugin: BuiltinPlugin(id: .time)) { context in
            TimeComparisonView(
                isExpanded: context.expanded, panelVisible: context.panelVisible,
                protectInteraction: context.protectInteraction)
        }
        return [time] + channelPlugins + [
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .fan, activate: { fan.activate() }, deactivate: { fan.stop() },
                    refresh: { fan.refresh() }, visibility: { fan.setPanelVisible($0) }),
                changes: fan.objectWillChange,
                indicator: { fan.error != nil || fan.snapshot.safetyPause != nil ? .error : .none },
                row: { context in
                    FanView(
                        model: fan, expanded: context.expanded, enablesHelperInstallation: enablesFanHelperInstallation)
                }),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .quickShutdown, activate: { shutdown.activate() }, deactivate: { shutdown.deactivate() },
                    refresh: { shutdown.refresh() }, visibility: { shutdown.panelDidChangeVisibility($0) }),
                changes: shutdown.objectWillChange,
                indicator: {
                    if shutdown.error != nil { return .error }
                    return shutdown.canCancel || shutdown.executing ? .active : .none
                },
                row: { context in
                    ShutdownSummary(controller: shutdown, open: context.openDetail)
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
                },
                row: { context in
                    UnattendedAuthSummary(controller: unattendedAuth, open: context.openDetail)
                }),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .windowDrag, activate: { windowDrag.start() }, deactivate: { windowDrag.stop() },
                    refresh: { windowDrag.refresh() }),
                changes: windowDrag.objectWillChange,
                indicator: { windowDrag.status.needsAttention ? .error : .none },
                row: { [weak self] context in
                    WindowDragSectionView(
                        monitor: windowDrag, expanded: context.expanded,
                        setModifier: { [weak self] in self?.setWindowDragModifier($0) })
                }),
            PanelPluginRegistration(
                plugin: remote, changes: remote.objectWillChange, available: { remote.available },
                row: { context in
                    RemoteRow(plugin: remote, open: context.openDetail)
                }),
            PanelPluginRegistration(
                plugin: translation, changes: translation.objectWillChange,
                indicator: {
                    if translation.hotKeyConflict != nil || translation.feedbackIsError { return .error }
                    return translation.busy || translation.translating || translation.ocrRunning ? .active : .none
                },
                row: { context in
                    TranslationSectionView(
                        model: translation, expanded: context.expanded, protectInteraction: context.protectInteraction)
                }),
            PanelPluginRegistration(
                plugin: tasks, changes: tasks.objectWillChange,
                indicator: {
                    if tasks.actionError != nil { return .error }
                    return tasks.loading || tasks.mutating ? .active : .none
                },
                row: { context in
                    TasksSummaryRow(model: tasks, open: context.openDetail)
                }),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(id: .weather, deactivate: { [weather] in weather.clear() }),
                row: { [weak self, weather, informationClient] context in
                    WeatherSection(
                        feed: weather, city: self?.weatherCity, client: informationClient,
                        visible: context.panelVisible, expanded: context.expanded,
                        selectCity: { [weak self] in self?.selectWeatherCity($0) },
                        protectInteraction: context.protectInteraction)
                }),
            PanelPluginRegistration(
                plugin: BuiltinPlugin(
                    id: .markets,
                    deactivate: { [marketFeeds] in
                        for feed in marketFeeds.values { feed.clear() }
                    }),
                row: { [marketFeeds, informationClient] context in
                    MarketsSection(
                        feeds: marketFeeds, client: informationClient,
                        visible: context.panelVisible, expanded: context.expanded)
                }),
            coverArchive.registration,
            openList.registration,
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
