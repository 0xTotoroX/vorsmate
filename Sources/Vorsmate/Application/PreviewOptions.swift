// [INPUT]: 应用启动参数、模块分类和默认偏好。
// [OUTPUT]: 内存预览的入口、模块开关与样例选项。
// [POS]: 预览参数的唯一解析点，普通启动不会应用预览偏好。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import VorsmateCore

struct PreviewOptions {
    private let flags: Set<String>

    init(arguments: [String]) {
        flags = arguments.contains("--preview") ? Set(arguments) : []
    }

    var enabled: Bool { flags.contains("--preview") }
    var dark: Bool { flags.contains("--preview-dark") }
    var light: Bool { flags.contains("--preview-light") }
    var popover: Bool { flags.contains("--preview-popover") }
    var longList: Bool { flags.contains("--preview-long-list") }
    var offlineTasks: Bool { flags.contains("--preview-tasks-offline") }
    var translationWindow: Bool { flags.contains("--preview-translate-window") }
    var unattendedDeadline: Bool { flags.contains("--preview-unattended-deadline") }
    var unattendedActive: Bool { unattendedDeadline || flags.contains("--preview-unattended-active") }
    var typelessRemote: Bool { flags.contains("--preview-typeless-remote") }
    var typelessTimeout: Bool { flags.contains("--preview-typeless-timeout") }
    private var tasksDetail: Bool { flags.contains("--preview-tasks-detail") }
    private var windowDrag: Bool { flags.contains("--preview-window-drag") }
    private var information: Bool { flags.contains("--preview-information") }
    private var translation: Bool { flags.contains("--preview-translate") }
    private var toolIntegrations: Bool { flags.contains("--preview-tool-integrations") }
    private var tasks: Bool { flags.contains("--preview-tasks") || tasksDetail || offlineTasks }

    var initialSection: PluginID? {
        if flags.contains("--preview-unattended-detail") { return .unattendedAuth }
        if windowDrag { return .windowDrag }
        if tasksDetail { return .tasks }
        return nil
    }

    var initialCategory: PluginCategory? {
        if let initialSection { return initialSection.defaultCategory }
        if translation || toolIntegrations { return .tools }
        if tasks || information { return .information }
        return nil
    }

    func apply(to preferences: inout Preferences) {
        if flags.contains("--preview-offline") {
            preferences[.audioInput] = SelectionPolicy(
                enabled: true,
                priority: [Source(id: "preview-offline", name: "DJI 无线麦克风接收器 · 桌面录音备用设备")],
                lockedID: "preview-offline"
            )
        }
        if windowDrag { preferences.windowDragEnabled = true }
        if popover { preferences.remoteEnabled = true }
        if information {
            preferences.weatherEnabled = true
            preferences.marketsEnabled = true
            preferences.weatherCity = WeatherCity(name: "示例市", latitude: 0, longitude: 0)
        }
        if translation || translationWindow { preferences.translateEnabled = true }
        if tasks { preferences.tasksEnabled = true }
        if toolIntegrations {
            preferences.coverArchiveEnabled = true
            preferences.openListEnabled = true
        }
    }
}
