// [INPUT]: FanHardware、控制配置、系统温度压力、单调续期与拥有权保存回调。
// [OUTPUT]: 自动 / 增强 / 固定调速与恢复；固定依系统压力和读数有效性保护，不以热点九十度阻断。
// [POS]: 助手内唯一写入者；等待增强不拥有硬件，实际写入前记录恢复责任。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import VorsmateCore

@MainActor
public final class FanRuntime {
    public private(set) var profiles: [Int: FanProfile] = [:]
    public private(set) var owned: Set<Int>
    public private(set) var message: String?
    public private(set) var safetyPause: FanSafetyPause?
    private let hardware: any FanHardware
    private let persist: (Set<Int>) throws -> Void
    private var heartbeat: TimeInterval?
    private var applied: [Int: Double] = [:]
    private var curves: [Int: FanCurveController] = [:]
    private var recoverySince: TimeInterval?
    public init(
        hardware: any FanHardware, owned: Set<Int> = [], persist: @escaping (Set<Int>) throws -> Void = { _ in }
    ) {
        self.hardware = hardware
        self.owned = owned
        self.persist = persist
    }
    public func renew(at time: TimeInterval) { heartbeat = time }
    public func snapshot() throws -> FanSnapshot {
        var state = try hardware.read()
        state.profiles = profiles
        state.message = message
        state.safetyPause = safetyPause
        return state
    }
    public func configure(
        fanID: Int, profile: FanProfile, at time: TimeInterval,
        thermalState: ProcessInfo.ThermalState = .nominal
    ) throws {
        let state = try hardware.read()
        guard let fan = state.fans.first(where: { $0.id == fanID }) else { throw FanFailure.unavailable }
        try profile.validate(for: fan)
        let elevated = thermalState == .serious || thermalState == .critical
        if profile.mode == .curve,
            elevated || !validTemperature(state.temperature) || !validTemperature(state.controlTemperature)
        {
            // 记录用户的智能选择，但不在无法判断温度时接管硬件。
            guard fan.hardwareMode != 1 || owned.contains(fanID) else { throw FanFailure.controlChanged }
            profiles[fanID] = profile
            heartbeat = time
            suspend(elevated ? .systemPressure : .temperatureUnavailable)
            return
        }
        // 新请求被拒绝没有改变硬件，不能复用运行中保护的“已交回系统”提示。
        if profile.mode == .fixed, elevated || !validTemperature(state.temperature) {
            throw FanFailure.fixedUnavailable
        }
        if profile.mode == .curve, fan.hardwareMode == 1, !owned.contains(fanID) { throw FanFailure.controlChanged }
        var curve = FanCurveController()
        let target =
            try profile.mode == .curve
            ? curve.target(for: fan, profile: profile, temperature: state.controlTemperature, at: time)
            : profile.target(for: fan, temperature: state.temperature)
        heartbeat = time
        do {
            if profile.mode == .system {
                // 显式恢复允许解除外部手动模式；待命轮询则不能取得这种权限。
                try claim(fanID)
                try restore(fanID)
                profiles[fanID] = nil
            } else {
                if let target {
                    try claim(fanID)
                    try hardware.setRPM(target, fanID: fanID)
                    applied[fanID] = target
                } else if owned.contains(fanID) {
                    try restore(fanID)
                }
                profiles[fanID] = profile
            }
            curves[fanID] = profile.mode == .curve ? curve : nil
            safetyPause = nil
            recoverySince = nil
            message = nil
        } catch {
            let original = error
            profiles[fanID] = nil
            curves[fanID] = nil
            do { if owned.contains(fanID) { try restore(fanID) } } catch {
                message = "调速失败，恢复系统也未确认：\(error.localizedDescription)"
                throw error
            }
            message = original.localizedDescription
            throw original
        }
    }
    private func claim(_ id: Int) throws {
        guard !owned.contains(id) else { return }
        var next = owned
        next.insert(id)
        try persist(next)  // 先记录恢复责任，再碰硬件；保护后恢复也走这一步。
        owned = next
    }
    private func restore(_ id: Int, clearCurve: Bool = true) throws {
        try hardware.restore(fanID: id)
        var next = owned
        next.remove(id)
        try persist(next)
        owned = next
        applied[id] = nil
        if clearCurve { curves[id] = nil }
    }
    private func releaseHardware() {
        for id in owned.sorted() {
            do { try restore(id) } catch { message = "恢复系统控制未确认：\(error.localizedDescription)" }
        }
    }
    public func releaseAll() {
        profiles.removeAll()
        curves.removeAll()
        heartbeat = nil
        safetyPause = nil
        recoverySince = nil
        releaseHardware()
    }
    private func suspend(_ reason: FanSafetyPause) {
        // 固定低速不自动重新接管；只有智能调速保留待恢复的意图。
        profiles = profiles.filter { $0.value.mode == .curve }
        curves.removeAll()
        recoverySince = nil
        safetyPause = profiles.isEmpty ? nil : reason
        message = profiles.isEmpty ? FanFailure.thermalLimit.localizedDescription : reason.message
        releaseHardware()
    }
    private func validTemperature(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite && value > 0 && value < 130
    }
    public func tick(at time: TimeInterval, thermalState: ProcessInfo.ThermalState = .nominal) {
        guard !owned.isEmpty || !profiles.isEmpty else { return }
        guard time.isFinite, let heartbeat, time >= heartbeat, time - heartbeat <= 12 else {
            message = "控制连接已结束，已请求交回系统控制。"
            releaseAll()
            return
        }
        if thermalState == .serious || thermalState == .critical {
            suspend(.systemPressure)
            return
        }
        do {
            let state = try hardware.read()
            guard validTemperature(state.temperature), let temperature = state.temperature else {
                suspend(.temperatureUnavailable)
                return
            }
            if profiles.values.contains(where: { $0.mode == .curve }), !validTemperature(state.controlTemperature) {
                suspend(.temperatureUnavailable)
                return
            }
            if safetyPause != nil {
                // 恢复回读未确认时只重试归还，不能提前写新的转速。
                if !owned.isEmpty {
                    releaseHardware()
                    return
                }
                guard !state.fans.contains(where: { profiles[$0.id] != nil && $0.hardwareMode == 1 }) else {
                    throw FanFailure.controlChanged
                }
                guard thermalState == .nominal || thermalState == .fair else {
                    recoverySince = nil
                    return
                }
                if recoverySince == nil || time < (recoverySince ?? time) { recoverySince = time }
                guard let recoverySince, time - recoverySince >= 10 else { return }
                safetyPause = nil
                self.recoverySince = nil
                message = nil
            }
            for (id, profile) in profiles.sorted(by: { $0.key < $1.key }) {
                guard let fan = state.fans.first(where: { $0.id == id }) else { throw FanFailure.unavailable }
                // 与上次确认的写入比较，不把自身的新目标误判为外部争抢。
                if let previous = applied[id] {
                    guard fan.hardwareMode == 1, abs(fan.targetRPM - previous) <= 150 else {
                        throw FanFailure.controlChanged
                    }
                } else if fan.hardwareMode == 1 {
                    throw FanFailure.controlChanged
                }
                let target =
                    try profile.mode == .curve
                    ? curves[id, default: FanCurveController()].target(
                        for: fan, profile: profile, temperature: state.controlTemperature, at: time)
                    : profile.target(for: fan, temperature: temperature)
                if let target {
                    let endpoint = target == fan.maximumRPM || target == max(500, fan.minimumRPM)
                    if applied[id] == nil || abs((applied[id] ?? 0) - target) >= 100
                        || (endpoint && applied[id] != target)
                    {
                        try claim(id)
                        try hardware.setRPM(target, fanID: id)
                        applied[id] = target
                    }
                } else if applied[id] != nil || fan.hardwareMode == 1 {
                    try restore(id, clearCurve: false)
                }
            }
        } catch {
            message = error.localizedDescription
            releaseAll()
        }
    }
}
