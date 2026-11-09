// [INPUT]: 风扇硬件范围、温度与用户控制模式。
// [OUTPUT]: 模式、读数和控制配置、曲线目标及有效性校验；预设参数由 FanCurvePreset 提供。
// [POS]: 风扇控制的纯规则；不访问硬件或执行权限操作。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum FanMode: String, Codable, CaseIterable, Sendable { case system, fixed, curve }

public struct FanReading: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var actualRPM: Double
    public var targetRPM: Double
    public var minimumRPM: Double
    public var maximumRPM: Double
    public var hardwareMode: Int
    public init(
        id: Int, actualRPM: Double, targetRPM: Double, minimumRPM: Double, maximumRPM: Double, hardwareMode: Int
    ) {
        self.id = id
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.hardwareMode = hardwareMode
    }
    public var hasValidRange: Bool {
        minimumRPM.isFinite && maximumRPM.isFinite && minimumRPM >= 0 && maximumRPM > max(minimumRPM, 500)
            && maximumRPM <= 20_000
    }
}

public struct FanProfile: Codable, Equatable, Sendable {
    public var mode: FanMode
    public var rpm: Double
    public var rampStart: Double
    public var fullSpeed: Double
    public init(mode: FanMode = .system, rpm: Double = 2000, rampStart: Double = 70, fullSpeed: Double = 95) {
        self.mode = mode
        self.rpm = rpm
        self.rampStart = rampStart
        self.fullSpeed = fullSpeed
    }
    // 预设沿用阈值识别；旧阈值仍按其原线性曲线读取，不改模式编码或数据格式。
    public var preset: FanCurvePreset? {
        guard mode == .curve else { return nil }
        return FanCurvePreset.allCases.first { rampStart == $0.profile.rampStart && fullSpeed == $0.profile.fullSpeed }
    }
    public func target(for fan: FanReading, temperature: Double?) throws -> Double? {
        guard mode != .system else { return nil }
        try validate(for: fan)
        guard let temperature, temperature.isFinite, temperature > 0, temperature < 130 else {
            throw FanFailure.thermalLimit
        }
        switch mode {
        case .system: return nil
        case .fixed:
            return rpm
        case .curve:
            guard temperature > rampStart else { return nil }
            let points = preset?.points ?? [(rampStart, 0.0), (fullSpeed, 1.0)]
            var fraction = 1.0
            for (lower, upper) in zip(points, points.dropFirst()) where temperature <= upper.0 {
                fraction = lower.1 + (upper.1 - lower.1) * (temperature - lower.0) / (upper.0 - lower.0)
                break
            }
            let minimum = max(500, fan.minimumRPM)
            return minimum + fraction * (fan.maximumRPM - minimum)
        }
    }
    public func validate(for fan: FanReading) throws {
        guard mode != .system else { return }
        guard fan.hasValidRange else { throw FanFailure.invalidRange }
        switch mode {
        case .system: break
        case .fixed:
            guard rpm.isFinite, rpm >= max(500, fan.minimumRPM), rpm <= fan.maximumRPM else {
                throw FanFailure.invalidRange
            }
        case .curve:
            guard rampStart.isFinite, fullSpeed.isFinite, rampStart >= 35, fullSpeed <= 110, fullSpeed - rampStart >= 10
            else { throw FanFailure.invalidCurve }
        }
    }
}

public enum FanSafetyPause: String, Codable, Sendable {
    case temperatureUnavailable, systemPressure
    public var message: String {
        switch self {
        case .temperatureUnavailable: "增强散热所需的温度读数暂不可用，已交回自动控制。"
        case .systemPressure: "系统正在处理温度压力，已交回自动控制；恢复稳定后继续增强散热。"
        }
    }
}

public struct FanSnapshot: Codable, Sendable {
    public var fans: [FanReading]
    public var temperature: Double?
    public var controlTemperature: Double?
    public var profiles: [Int: FanProfile]
    public var message: String?
    public var safetyPause: FanSafetyPause?
    public init(
        fans: [FanReading] = [], temperature: Double? = nil, controlTemperature: Double? = nil,
        profiles: [Int: FanProfile] = [:], message: String? = nil, safetyPause: FanSafetyPause? = nil
    ) {
        self.fans = fans
        self.temperature = temperature
        self.controlTemperature = controlTemperature
        self.profiles = profiles
        self.message = message
        self.safetyPause = safetyPause
    }
}

public enum FanFailure: LocalizedError {
    case unavailable, invalidRange, invalidCurve, fixedUnavailable, thermalLimit, timeout, connectionTimeout,
        notAuthorized, competingTool, controlChanged
    case hardware(String)
    case remote(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "没有可用的风扇或温度读数。"
        case .invalidRange: "转速超出这台 Mac 的可用范围。"
        case .invalidCurve: "散热配置无效，请重新选择均衡或强冷。"
        case .fixedUnavailable: "当前温度状态不允许固定转速，此次切换未生效。"
        case .thermalLimit: "温度过高或读数不可用，已请求交回系统控制。"
        case .timeout: "风扇控制未通过回读确认，请检查系统助手。"
        case .connectionTimeout: "风扇助手暂未响应，正在重新确认控制状态。"
        case .notAuthorized: "需要先启用风扇控制助手。"
        case .competingTool: "请先退出 Macs Fan Control 等其他风扇控制工具。"
        case .controlChanged: "风扇控制被其他来源改变，已停止调速并请求交回系统。"
        case .hardware(let detail): "风扇访问失败：\(detail)"
        case .remote(let message): message
        }
    }
}
