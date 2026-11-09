// [INPUT]: 增强散热档位与已核验机型的可调转速区间。
// [OUTPUT]: 均衡 / 强冷分段曲线及各自的平滑、确认、升降速和趋势参数。
// [POS]: 风扇偏好参数唯一来源；温度有效性与运行时保护由对应规则负责。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum FanCurvePreset: String, CaseIterable, Sendable {
    case balanced, cooling

    public var title: String {
        switch self {
        case .balanced: "均衡"
        case .cooling: "强冷"
        }
    }
    public var profile: FanProfile {
        switch self {
        case .balanced: FanProfile(mode: .curve, rampStart: 70, fullSpeed: 95)
        case .cooling: FanProfile(mode: .curve, rampStart: 60, fullSpeed: 90)
        }
    }
    public var confirmationTime: TimeInterval { response.confirmationTime }

    // 百分比对应本机可调转速区间，并非风量、PWM 或 Apple 温度极限。
    var points: [(temperature: Double, fraction: Double)] {
        switch self {
        case .balanced: [(70, 0), (75, 0.15), (80, 0.30), (85, 0.45), (90, 0.70), (95, 1)]
        case .cooling: [(60, 0), (65, 0.15), (70, 0.30), (75, 0.45), (80, 0.65), (85, 0.85), (90, 1)]
        }
    }
    var response: FanCurveResponse {
        switch self {
        case .balanced:
            FanCurveResponse(
                riseTime: 8, fallTime: 25, confirmationTime: 8,
                acceleration: 150, deceleration: 60, coolingHold: 20, releaseTime: 30,
                lookAhead: 6, maximumLead: 2)
        case .cooling:
            FanCurveResponse(
                riseTime: 4, fallTime: 30, confirmationTime: 4,
                acceleration: 300, deceleration: 80, coolingHold: 30, releaseTime: 45,
                lookAhead: 10, maximumLead: 4)
        }
    }
}

struct FanCurveResponse: Sendable {
    var riseTime: TimeInterval = 10
    var fallTime: TimeInterval = 20
    var confirmationTime: TimeInterval = 20
    var acceleration = 150.0
    var deceleration = 100.0
    var coolingHold: TimeInterval = 8
    var releaseTime: TimeInterval = 20
    var lookAhead = 0.0
    var maximumLead = 0.0
}
