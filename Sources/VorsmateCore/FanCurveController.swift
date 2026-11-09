// [INPUT]: 已核验的参考温度、增强配置、硬件当前目标与单调时钟。
// [OUTPUT]: 分档平滑、有限升温趋势提前量、持续确认与缓降回差；低负载交还系统。
// [POS]: 每个风扇独立的内存状态；系统温度压力由运行时优先处理。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct FanCurveController: Sendable {
    private var filteredTemperature: Double?
    private var lastUpdate: TimeInterval?
    private var requestedRPM: Double?
    private var warmSince: TimeInterval?
    private var coolSince: TimeInterval?
    private var coolingSince: TimeInterval?
    private var risingSince: TimeInterval?
    private var lastTemperature: Double?
    private var automaticFloor = 0.0

    public init() {}

    public mutating func target(for fan: FanReading, profile: FanProfile, temperature: Double?, at time: TimeInterval)
        throws -> Double?
    {
        guard profile.mode == .curve else { throw FanFailure.invalidCurve }
        let rawTarget = try profile.target(for: fan, temperature: temperature)
        guard let temperature, time.isFinite, lastUpdate.map({ time >= $0 }) ?? true else { throw FanFailure.timeout }
        let elapsed = lastUpdate.map { time - $0 } ?? 0
        lastUpdate = time
        let response = profile.preset?.response ?? FanCurveResponse()
        if elapsed > 6 {
            warmSince = nil
            coolSince = nil
            coolingSince = nil
            risingSince = nil
        }
        let previous = filteredTemperature ?? min(temperature, profile.fullSpeed)
        let tau = temperature > previous ? response.riseTime : response.fallTime
        let filtered = min(profile.fullSpeed, previous + (temperature - previous) * (1 - exp(-elapsed / tau)))
        filteredTemperature = filtered
        let observed = try profile.target(for: fan, temperature: filtered)
        let minimum = max(500, fan.minimumRPM)
        // 连续上升四秒才采用有限提前量；单次尖峰和采样缺口不构成趋势。
        if elapsed > 0 {
            if elapsed <= 6, temperature > (lastTemperature ?? temperature), filtered > previous {
                risingSince = risingSince ?? time
            } else {
                risingSince = nil
            }
            lastTemperature = temperature
        } else if lastTemperature == nil {
            lastTemperature = temperature
        }
        let lead: Double
        if let risingSince, time - risingSince >= 4, elapsed > 0 {
            lead = min(response.maximumLead, max(0, (filtered - previous) / elapsed * response.lookAhead))
        } else {
            lead = 0
        }
        let desired = try profile.target(for: fan, temperature: min(profile.fullSpeed, filtered + lead))

        if requestedRPM == nil {
            // 接管前一直保持自动；只在我们的目标高于系统当前目标时增强。
            automaticFloor = min(fan.maximumRPM, max(minimum, fan.targetRPM))
            if let rawTarget, rawTarget > automaticFloor + 100,
                let observed, observed > automaticFloor + 100
            {
                warmSince = warmSince ?? time
            } else {
                warmSince = nil
            }
            guard let warmSince, time - warmSince >= response.confirmationTime else { return nil }
            requestedRPM = min(fan.maximumRPM, max(automaticFloor, fan.actualRPM))
            self.warmSince = nil
            return requestedRPM
        }

        let goal = max(automaticFloor, desired ?? minimum)
        let previousRPM = requestedRPM ?? automaticFloor
        let next: Double
        let endpoint = goal == fan.maximumRPM || goal == automaticFloor
        if abs(goal - previousRPM) < 100, !endpoint {
            coolingSince = nil
            next = previousRPM
        } else if goal >= previousRPM {
            coolingSince = nil
            next = min(goal, previousRPM + response.acceleration * elapsed)
        } else {
            coolingSince = coolingSince ?? time
            let coolingElapsed = max(0, time - max(time - elapsed, (coolingSince ?? time) + response.coolingHold))
            next = max(goal, previousRPM - response.deceleration * coolingElapsed)
        }
        // 用曲线本身计算三度回差，兼容分段曲线与较高的进入前系统目标。
        let releaseTarget = try profile.target(for: fan, temperature: min(129, temperature + 3)) ?? minimum
        if releaseTarget <= automaticFloor, (observed ?? minimum) <= automaticFloor {
            coolSince = coolSince ?? time
        } else {
            coolSince = nil
        }
        if let coolSince, time - coolSince >= response.releaseTime, next <= automaticFloor + 100 {
            requestedRPM = nil
            warmSince = nil
            self.coolSince = nil
            coolingSince = nil
            return nil
        }
        requestedRPM = next
        return next
    }
}
