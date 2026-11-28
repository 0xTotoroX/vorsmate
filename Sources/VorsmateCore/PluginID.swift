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
    case weather, markets, windowDrag
    public var id: Self { self }
    public var title: String {
        switch self {
        case .time: "时间对照"
        case .inputSource: "输入法"
        case .audioInput: "麦克风"
        case .audioOutput: "播放设备"
        case .fan: "风扇"
        case .quickShutdown: "一键关机"
        case .unattendedAuth: "无人值守授权"
        case .remote: "遥控器"
        case .translate: "截图"
        case .windowDrag: "窗口拖动"
        case .tasks: "待办"
        case .weather: "天气"
        case .markets: "行情"
        }
    }
    public var symbol: String {
        switch self {
        case .time: "clock"
        case .inputSource: "keyboard"
        case .audioInput: "mic"
        case .audioOutput: "speaker.wave.2"
        case .fan: "fan"
        case .quickShutdown: "sunset"
        case .unattendedAuth: "lock.shield"
        case .remote: "appletvremote.gen4"
        case .translate: "viewfinder"
        case .windowDrag: "arrow.up.and.down.and.arrow.left.and.right"
        case .tasks: "checklist"
        case .weather: "cloud.sun"
        case .markets: "chart.line.uptrend.xyaxis"
        }
    }
    public var defaultCategory: PluginCategory {
        switch self {
        case .time, .tasks, .weather, .markets:
            .information
        case .translate, .remote, .windowDrag:
            .tools
        case .inputSource, .audioInput, .audioOutput, .fan, .quickShutdown, .unattendedAuth:
            .system
        }
    }
    public var channel: Channel? { Channel(rawValue: rawValue) }
}
