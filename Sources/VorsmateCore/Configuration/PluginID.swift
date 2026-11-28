// [INPUT]: Foundation 与现有 Channel 标识。
// [OUTPUT]: 内置与可选插件的稳定标识、顺序、默认分类与界面元数据。
// [POS]: 注册表与配置共用的插件身份；不持有运行资源。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum PluginCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case information
    case tools
    case system

    public var id: Self { self }

    public var title: String {
        switch self {
        case .information: "信息"
        case .tools: "工具"
        case .system: "系统"
        }
    }

    public var symbol: String {
        switch self {
        case .information: "info.circle"
        case .tools: "wrench.and.screwdriver"
        case .system: "gearshape"
        }
    }

    public init?(savedValue: String) {
        self.init(rawValue: savedValue == "devices" ? Self.system.rawValue : savedValue)
    }

    public func orderedPlugins(in order: [PluginID]) -> [PluginID] {
        let members = order.filter { $0.defaultCategory == self }
        guard self == .information, members.contains(.tasks) else { return members }
        return members.filter { $0 != .tasks } + [.tasks]
    }

    public func canReorder(_ id: PluginID) -> Bool {
        id.defaultCategory == self && id != .tasks
    }
}

public enum PluginID: String, Codable, CaseIterable, Sendable, Identifiable {
    case time, inputSource, audioInput, audioOutput, fan, quickShutdown, unattendedAuth, remote, translate, tasks
    case weather, markets, windowDrag, coverArchive, openList

    public var id: Self { self }

    public var title: String { presentation.title }
    public var symbol: String { presentation.symbol }
    public var defaultCategory: PluginCategory { presentation.category }
    public var channel: Channel? { Channel(rawValue: rawValue) }

    private var presentation: (title: String, symbol: String, category: PluginCategory) {
        switch self {
        case .time: ("时间对照", "clock", .information)
        case .inputSource: ("输入法", "keyboard", .system)
        case .audioInput: ("麦克风", "mic", .system)
        case .audioOutput: ("播放设备", "speaker.wave.2", .system)
        case .fan: ("风扇", "fan", .system)
        case .quickShutdown: ("一键关机", "sunset", .system)
        case .unattendedAuth: ("无人值守授权", "lock.shield", .system)
        case .remote: ("遥控器", "appletvremote.gen4", .tools)
        case .translate: ("截图", "viewfinder", .tools)
        case .windowDrag: ("窗口拖动", "arrow.up.and.down.and.arrow.left.and.right", .tools)
        case .tasks: ("待办", "checklist", .information)
        case .weather: ("天气", "cloud.sun", .information)
        case .markets: ("行情", "chart.line.uptrend.xyaxis", .information)
        case .coverArchive: ("收藏封面", "music.note.list", .tools)
        case .openList: ("网盘", "externaldrive.connected.to.line.below", .tools)
        }
    }
}
