// [INPUT]: Foundation 与现有 Channel 标识。
// [OUTPUT]: 六个内置插件的稳定标识、顺序与界面元数据。
// [POS]: 注册表与配置共用的插件身份；不持有运行资源。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum PluginID: String, Codable, CaseIterable, Sendable, Identifiable {
    case time, inputSource, audioInput, audioOutput, fan, quickShutdown
    public var id: Self { self }
    public var title: String {
        switch self {
        case .time: "时间对照"
        case .inputSource: "输入法"
        case .audioInput: "麦克风"
        case .audioOutput: "播放设备"
        case .fan: "风扇"
        case .quickShutdown: "一键下班"
        }
    }
    public var symbol: String {
        switch self {
        case .time: "clock"
        case .inputSource: "keyboard"
        case .audioInput: "mic"
        case .audioOutput: "speaker.wave.2"
        case .fan: "fan"
        case .quickShutdown: "power"
        }
    }
    public var channel: Channel? { Channel(rawValue: rawValue) }
}
