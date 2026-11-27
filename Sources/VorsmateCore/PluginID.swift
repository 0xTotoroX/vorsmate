// [INPUT]: Foundation 与现有 Channel 标识。
// [OUTPUT]: 内置与可选插件的稳定标识、顺序、默认分类与界面元数据。
// [POS]: 注册表与配置共用的插件身份；不持有运行资源。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum PluginCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case devices
    case tools
    case system

    public var id: Self { self }

    public var title: String {
        switch self {
        case .devices: "设备"
        case .tools: "工具"
        case .system: "系统"
        }
    }

    public var symbol: String {
        switch self {
        case .devices: "slider.horizontal.3"
        case .tools: "viewfinder"
        case .system: "gearshape"
        }
    }
}

public enum PluginID: String, Codable, CaseIterable, Sendable, Identifiable {
    case time, inputSource, audioInput, audioOutput, fan, quickShutdown, unattendedAuth, remote, translate
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
        }
    }
    public var defaultCategory: PluginCategory {
        switch self {
        case .time, .inputSource, .audioInput, .audioOutput, .fan:
            .devices
        case .translate, .remote:
            .tools
        case .quickShutdown, .unattendedAuth:
            .system
        }
    }
    public var channel: Channel? { Channel(rawValue: rawValue) }
}
