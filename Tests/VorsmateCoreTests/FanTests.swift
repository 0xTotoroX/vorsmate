// [INPUT]: 自动优先的风扇规则、FanRuntime 与独立热点 / 参考温度替身。
// [OUTPUT]: 高热点时固定可选可持续、系统压力保护、拒绝切换状态、写前责任及失联验证。
// [POS]: 风扇安全边界测试，不向真实硬件写入。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateFan

private let fanFixture = FanReading(
    id: 0, actualRPM: 2000, targetRPM: 2000, minimumRPM: 1000, maximumRPM: 4900, hardwareMode: 0)

@Suite("风扇规则")
struct FanPolicyTests {
    @Test("均衡与强冷有明确顺序，旧配置和快照仍可读取")
    func presetsAndCompatibility() throws {
        for preset in FanCurvePreset.allCases {
            try preset.profile.validate(for: fanFixture)
            let decoded = try JSONDecoder().decode(FanProfile.self, from: JSONEncoder().encode(preset.profile))
            #expect(decoded.preset == preset)
            #expect(try decoded.target(for: fanFixture, temperature: 115) == fanFixture.maximumRPM)
        }
        for temperature in stride(from: 40.0, through: 120, by: 1) {
            let targets = try FanCurvePreset.allCases.map {
                try $0.profile.target(for: fanFixture, temperature: temperature) ?? fanFixture.minimumRPM
            }
            #expect(targets[0] <= targets[1])
        }
        let legacy = Data(#"{"mode":"curve","rpm":2000,"rampStart":55,"fullSpeed":80}"#.utf8)
        let decoded = try JSONDecoder().decode(FanProfile.self, from: legacy)
        #expect(decoded.rampStart == 55 && decoded.fullSpeed == 80 && decoded.mode == .curve)
        let snapshot = try JSONDecoder().decode(
            FanSnapshot.self, from: Data(#"{"fans":[],"temperature":98,"profiles":{}}"#.utf8))
        #expect(snapshot.temperature == 98 && snapshot.controlTemperature == nil)
    }
    @Test("固定转速在硬件范围内，拒绝非有限数与过低转速")
    func fixedLimits() throws {
        #expect(try FanProfile(mode: .fixed, rpm: 2500).target(for: fanFixture, temperature: 60) == 2500)
        for value in [0, 999, 5000, .nan, .infinity] {
            #expect(throws: FanFailure.self) {
                try FanProfile(mode: .fixed, rpm: value).target(for: fanFixture, temperature: 60)
            }
        }
    }
    @Test("参考温度低于起点保持自动，持续高温可达硬件上限")
    func curve() throws {
        let profile = FanCurvePreset.balanced.profile
        #expect(try profile.target(for: fanFixture, temperature: 70) == nil)
        #expect(try profile.target(for: fanFixture, temperature: 80) == 2170)
        #expect(try profile.target(for: fanFixture, temperature: 110) == 4900)
    }
    @Test("固定转速拒绝无效温度，不将有效核心热点误当作系统压力")
    func temperatureGuard() {
        for temperature: Double? in [nil, .nan, .infinity, 0, 130] {
            #expect(throws: FanFailure.self) {
                try FanProfile(mode: .fixed).target(for: fanFixture, temperature: temperature)
            }
        }
    }
    @Test("拒绝倒置、过热、非有限值曲线")
    func badCurve() {
        for profile in [
            FanProfile(mode: .curve, rampStart: 80, fullSpeed: 70),
            FanProfile(mode: .curve, rampStart: 85, fullSpeed: 120),
            FanProfile(mode: .curve, rampStart: .nan),
        ] {
            #expect(throws: FanFailure.self) { try profile.target(for: fanFixture, temperature: 95) }
        }
    }
}

@MainActor
private final class FanFixtureDriver: FanHardware {
    var reading = fanFixture
    var temperature: Double? = 60
    var reference: Double? = 95
    var writes: [Double] = []
    var restored: [Int] = []
    var failWrite = false
    var failRestore = false
    func read() throws -> FanSnapshot {
        FanSnapshot(fans: [reading], temperature: temperature, controlTemperature: reference)
    }
    func setRPM(_ rpm: Double, fanID: Int) throws {
        writes.append(rpm)
        reading.hardwareMode = 1
        if failWrite { throw FanFailure.timeout }
        reading.targetRPM = rpm
    }
    func restore(fanID: Int) throws {
        restored.append(fanID)
        if failRestore { throw FanFailure.timeout }
        reading.hardwareMode = 0
        reading.targetRPM = 2000
        reading.actualRPM = 2000
    }
}

@Suite("风扇运行时")
@MainActor
struct FanRuntimeTests {
    private func advance(
        _ runtime: FanRuntime, from: Double, through end: Double,
        pressure: ProcessInfo.ThermalState = .nominal
    ) {
        for time in stride(from: from, through: end, by: 2) {
            runtime.renew(at: time)
            runtime.tick(at: time, thermalState: pressure)
        }
    }
    private func activate(_ runtime: FanRuntime) throws {
        try runtime.configure(fanID: 0, profile: FanCurvePreset.balanced.profile, at: 0)
        advance(runtime, from: 2, through: 40)
    }

    @Test("固定请求因温度被拒绝时保留原模式，不声称已经交回系统", arguments: [false, true])
    func fixedRejectionPreservesMode(enhanced: Bool) throws {
        let conditions: [(Double?, ProcessInfo.ThermalState)] = [
            (nil, .nominal), (130, .nominal), (60, .serious), (60, .critical),
        ]
        for (temperature, pressure) in conditions {
            let hardware = FanFixtureDriver()
            let runtime = FanRuntime(hardware: hardware)
            if enhanced {
                try runtime.configure(fanID: 0, profile: FanCurvePreset.cooling.profile, at: 0)
                advance(runtime, from: 2, through: 40)
            }
            hardware.temperature = temperature
            let before = try runtime.snapshot()
            let owned = runtime.owned
            let writeCount = hardware.writes.count
            let restoreCount = hardware.restored.count
            var rejection: Error?
            do {
                try runtime.configure(fanID: 0, profile: .init(mode: .fixed, rpm: 2500), at: 42, thermalState: pressure)
            } catch { rejection = error }
            #expect(rejection?.localizedDescription == "当前温度状态不允许固定转速，此次切换未生效。")
            #expect(runtime.profiles == before.profiles && runtime.owned == owned)
            #expect(hardware.reading == before.fans.first)
            #expect(hardware.writes.count == writeCount && hardware.restored.count == restoreCount)
        }
    }

    @Test("热点超过九十度且系统压力正常时可以选中固定并持续保持", arguments: [false, true])
    func fixedRemainsAvailableWithValidHotspot(enhanced: Bool) throws {
        for pressure: ProcessInfo.ThermalState in [.nominal, .fair] {
            let hardware = FanFixtureDriver()
            let runtime = FanRuntime(hardware: hardware)
            if enhanced {
                try runtime.configure(fanID: 0, profile: FanCurvePreset.cooling.profile, at: 0)
                advance(runtime, from: 2, through: 40)
            }
            hardware.temperature = 103
            try runtime.configure(fanID: 0, profile: .init(mode: .fixed, rpm: 2500), at: 42, thermalState: pressure)
            for time in stride(from: 44.0, through: 104, by: 2) {
                hardware.temperature = Int(time).isMultiple(of: 4) ? 97 : 110
                runtime.renew(at: time)
                runtime.tick(at: time, thermalState: pressure)
                #expect(runtime.profiles[0] == FanProfile(mode: .fixed, rpm: 2500))
                #expect(hardware.reading.hardwareMode == 1 && hardware.reading.targetRPM == 2500)
                #expect(runtime.owned == [0] && runtime.message == nil)
            }
            try runtime.configure(fanID: 0, profile: .init(mode: .fixed, rpm: 3000), at: 106, thermalState: pressure)
            #expect(hardware.reading.targetRPM == 3000 && runtime.profiles[0]?.rpm == 3000)
            try runtime.configure(fanID: 0, profile: .init(mode: .system), at: 108, thermalState: pressure)
            #expect(hardware.reading.hardwareMode == 0 && runtime.profiles.isEmpty && runtime.owned.isEmpty)
        }
    }

    @Test("自动模式不因最高热点九十到一百二十度擅自接管")
    func automaticNeverOverrides() throws {
        let hardware = FanFixtureDriver()
        let runtime = FanRuntime(hardware: hardware)
        try runtime.configure(fanID: 0, profile: .init(mode: .system), at: 0)
        let restoreCount = hardware.restored.count
        for time in stride(from: 2.0, through: 60, by: 2) {
            hardware.temperature = Int(time).isMultiple(of: 4) ? 120 : 94
            runtime.renew(at: time)
            runtime.tick(at: time)
        }
        #expect(hardware.writes.isEmpty && hardware.restored.count == restoreCount)
        #expect(runtime.profiles.isEmpty && hardware.reading.hardwareMode == 0)
    }
    @Test("核心热点不用于增强曲线，参考温度偏低时仍由系统管理")
    func hotspotDoesNotDriveCurve() throws {
        let hardware = FanFixtureDriver()
        hardware.temperature = 104
        hardware.reference = 65
        let runtime = FanRuntime(hardware: hardware)
        try activate(runtime)
        #expect(hardware.writes.isEmpty && hardware.restored.isEmpty)
        #expect(runtime.owned.isEmpty && runtime.profiles[0]?.mode == .curve)
        #expect(try runtime.snapshot().temperature == 104)
    }
    @Test("选择增强到持续升温确认期间不写硬件也不登记拥有权")
    func waitBeforeOwnership() throws {
        let hardware = FanFixtureDriver()
        var saved: Set<Int> = []
        let runtime = FanRuntime(hardware: hardware, persist: { saved = $0 })
        try runtime.configure(fanID: 0, profile: FanCurvePreset.balanced.profile, at: 0)
        advance(runtime, from: 2, through: 6)
        #expect(hardware.writes.isEmpty && hardware.restored.isEmpty && saved.isEmpty)
        advance(runtime, from: 8, through: 40)
        #expect(hardware.reading.hardwareMode == 1 && saved == [0])
    }
    @Test("参考温度缺失不能退回最高热点继续调速")
    func missingReference() throws {
        let hardware = FanFixtureDriver()
        hardware.temperature = 100
        hardware.reference = nil
        let runtime = FanRuntime(hardware: hardware)
        try activate(runtime)
        #expect(hardware.writes.isEmpty && runtime.owned.isEmpty)
        #expect(runtime.safetyPause == .temperatureUnavailable && runtime.profiles[0]?.mode == .curve)
    }
    @Test("持久化恢复责任失败时禁止硬件写入")
    func ownershipBeforeWrite() throws {
        let hardware = FanFixtureDriver()
        let runtime = FanRuntime(hardware: hardware, persist: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: CocoaError.self) { try runtime.configure(fanID: 0, profile: .init(mode: .fixed), at: 0) }
        #expect(hardware.writes.isEmpty && runtime.owned.isEmpty)
        try runtime.configure(fanID: 0, profile: FanCurvePreset.balanced.profile, at: 2)
        advance(runtime, from: 4, through: 24)
        #expect(hardware.writes.isEmpty && runtime.profiles.isEmpty)
    }
    @Test("失联超过租约时恢复自动且清除模式")
    func leaseExpires() throws {
        let hardware = FanFixtureDriver()
        var saved: Set<Int> = []
        let runtime = FanRuntime(hardware: hardware, persist: { saved = $0 })
        try activate(runtime)
        #expect(saved == [0])
        runtime.tick(at: 53)
        #expect(hardware.restored == [0])
        #expect(runtime.profiles.isEmpty && runtime.owned.isEmpty && saved.isEmpty)
    }
    @Test("增强持续高温可全速，冷却释放拥有权并保留选择")
    func curveLifecycle() throws {
        let hardware = FanFixtureDriver()
        hardware.reference = 110
        hardware.temperature = 120
        let runtime = FanRuntime(hardware: hardware)
        try activate(runtime)
        advance(runtime, from: 42, through: 60)
        #expect(hardware.writes.last == 4900)
        hardware.reference = 65
        advance(runtime, from: 62, through: 180)
        #expect(hardware.reading.hardwareMode == 0 && runtime.owned.isEmpty)
        #expect(runtime.profiles[0]?.mode == .curve)
        hardware.reference = 110
        advance(runtime, from: 182, through: 240)
        #expect(hardware.reading.hardwareMode == 1 && hardware.writes.last == 4900)
    }
    @Test("原始读数或参考温度丢失立即归还，稳定后重新确认持续升温")
    func invalidReadingsRecover() throws {
        for missingReference in [false, true] {
            let hardware = FanFixtureDriver()
            let runtime = FanRuntime(hardware: hardware)
            try activate(runtime)
            if missingReference { hardware.reference = nil } else { hardware.temperature = nil }
            runtime.tick(at: 42)
            #expect(hardware.reading.hardwareMode == 0 && runtime.owned.isEmpty)
            #expect(runtime.safetyPause == .temperatureUnavailable && runtime.profiles[0]?.mode == .curve)
            hardware.temperature = 100
            hardware.reference = 95
            advance(runtime, from: 44, through: 60)
            #expect(hardware.reading.hardwareMode == 0)
            advance(runtime, from: 62, through: 90)
            #expect(hardware.reading.hardwareMode == 1 && runtime.safetyPause == nil)
        }
    }
    @Test("系统严重或临界压力优先接管，增强选择保留，固定不自动恢复")
    func systemPressure() throws {
        for pressure: ProcessInfo.ThermalState in [.serious, .critical] {
            let hardware = FanFixtureDriver()
            var saved: Set<Int> = []
            let runtime = FanRuntime(hardware: hardware, persist: { saved = $0 })
            try activate(runtime)
            runtime.tick(at: 42, thermalState: pressure)
            let count = hardware.writes.count
            #expect(hardware.reading.hardwareMode == 0 && saved.isEmpty)
            advance(runtime, from: 44, through: 60, pressure: .serious)
            #expect(hardware.writes.count == count && runtime.profiles[0]?.mode == .curve)
            advance(runtime, from: 62, through: 78, pressure: .fair)
            #expect(hardware.writes.count == count)
            advance(runtime, from: 80, through: 110)
            #expect(hardware.reading.hardwareMode == 1 && saved == [0])
            try runtime.configure(fanID: 0, profile: .init(mode: .fixed), at: 112)
            runtime.tick(at: 114, thermalState: pressure)
            #expect(runtime.profiles.isEmpty && hardware.reading.hardwareMode == 0)
        }
    }
    @Test("固定模式运行中失去有效温度仍交还系统，不保留手动转速")
    func fixedLosesTemperature() throws {
        for temperature: Double? in [nil, .nan, 0, 130] {
            let hardware = FanFixtureDriver()
            hardware.temperature = 103
            let runtime = FanRuntime(hardware: hardware)
            try runtime.configure(fanID: 0, profile: .init(mode: .fixed, rpm: 2500), at: 0)
            hardware.temperature = temperature
            runtime.tick(at: 2)
            #expect(hardware.reading.hardwareMode == 0 && runtime.owned.isEmpty && runtime.profiles.isEmpty)
            #expect(hardware.restored == [0])
        }
    }
    @Test("压力较高时选增强先待命，显式自动会取消等待")
    func configureWhileProtected() throws {
        let hardware = FanFixtureDriver()
        let runtime = FanRuntime(hardware: hardware)
        try runtime.configure(fanID: 0, profile: FanCurvePreset.balanced.profile, at: 0, thermalState: .serious)
        #expect(hardware.writes.isEmpty && runtime.owned.isEmpty && runtime.safetyPause == .systemPressure)
        try runtime.configure(fanID: 0, profile: .init(mode: .system), at: 2)
        advance(runtime, from: 4, through: 60)
        #expect(runtime.profiles.isEmpty && runtime.safetyPause == nil && hardware.writes.isEmpty)
    }
    @Test("读数再次丢失重计稳定时间，保护期间失联终止本次增强")
    func interruptedRecoveryAndLease() throws {
        let hardware = FanFixtureDriver()
        let runtime = FanRuntime(hardware: hardware)
        try activate(runtime)
        let count = hardware.writes.count
        hardware.reference = nil
        runtime.tick(at: 42)
        hardware.reference = 95
        advance(runtime, from: 44, through: 50)
        hardware.reference = nil
        runtime.tick(at: 52)
        hardware.reference = 95
        advance(runtime, from: 54, through: 60)
        runtime.tick(at: 73)
        #expect(runtime.profiles.isEmpty && runtime.safetyPause == nil)
        advance(runtime, from: 74, through: 120)
        #expect(hardware.writes.count == count)
    }
    @Test("待命和保护期间外部接管时停止等待，不触碰外部控制")
    func externalWhileWaiting() throws {
        for protected in [false, true] {
            let hardware = FanFixtureDriver()
            let runtime = FanRuntime(hardware: hardware)
            if protected {
                try activate(runtime)
                runtime.tick(at: 42, thermalState: .critical)
            } else {
                try runtime.configure(fanID: 0, profile: FanCurvePreset.balanced.profile, at: 42)
            }
            let restored = hardware.restored.count
            hardware.reading.hardwareMode = 1
            hardware.reading.targetRPM = 3000
            runtime.renew(at: 44)
            runtime.tick(at: 44)
            #expect(runtime.profiles.isEmpty && runtime.owned.isEmpty)
            #expect(hardware.reading.hardwareMode == 1 && hardware.reading.targetRPM == 3000)
            #expect(hardware.restored.count == restored)
        }
    }
    @Test("恢复失败时保留责任重试，成功后才重新计时")
    func protectedRestoreFailure() throws {
        let hardware = FanFixtureDriver()
        let runtime = FanRuntime(hardware: hardware)
        try activate(runtime)
        let count = hardware.writes.count
        hardware.failRestore = true
        runtime.tick(at: 42, thermalState: .critical)
        advance(runtime, from: 44, through: 60)
        #expect(runtime.owned == [0] && hardware.writes.count == count)
        hardware.failRestore = false
        advance(runtime, from: 62, through: 80)
        #expect(runtime.owned.isEmpty && hardware.reading.hardwareMode == 0)
        advance(runtime, from: 82, through: 110)
        #expect(runtime.owned == [0] && hardware.reading.hardwareMode == 1)
    }
    @Test("保护后恢复责任保存失败时不重新写入")
    func resumeOwnershipFailure() throws {
        let hardware = FanFixtureDriver()
        var reject = false
        let runtime = FanRuntime(
            hardware: hardware,
            persist: { ids in if reject && !ids.isEmpty { throw CocoaError(.fileWriteNoPermission) } })
        try activate(runtime)
        let count = hardware.writes.count
        runtime.tick(at: 42, thermalState: .critical)
        reject = true
        advance(runtime, from: 44, through: 90)
        #expect(hardware.writes.count == count && hardware.reading.hardwareMode == 0)
        #expect(runtime.owned.isEmpty && runtime.profiles.isEmpty)
    }
    @Test("系统已恢复但责任文件未保存时保留重试责任")
    func restorePersistenceFailure() throws {
        let hardware = FanFixtureDriver()
        var reject = false
        let runtime = FanRuntime(
            hardware: hardware,
            persist: { ids in if reject && ids.isEmpty { throw CocoaError(.fileWriteNoPermission) } })
        try runtime.configure(fanID: 0, profile: .init(mode: .fixed), at: 0)
        reject = true
        #expect(throws: CocoaError.self) { try runtime.configure(fanID: 0, profile: .init(mode: .system), at: 2) }
        #expect(hardware.reading.hardwareMode == 0 && runtime.owned == [0])
        reject = false
        runtime.tick(at: 20)
        #expect(runtime.owned.isEmpty)
    }
    @Test("重启恢复只处理已有责任记录")
    func restartRecovery() {
        let hardware = FanFixtureDriver()
        hardware.reading.hardwareMode = 1
        FanRuntime(hardware: hardware).releaseAll()
        #expect(hardware.restored.isEmpty)
        let runtime = FanRuntime(hardware: hardware, owned: [0])
        runtime.releaseAll()
        #expect(hardware.restored == [0] && runtime.owned.isEmpty)
    }
    @Test("写入失败回滚，恢复失败保留责任")
    func failureRecovery() throws {
        let hardware = FanFixtureDriver()
        hardware.failWrite = true
        hardware.failRestore = true
        let runtime = FanRuntime(hardware: hardware)
        #expect(throws: FanFailure.self) { try runtime.configure(fanID: 0, profile: .init(mode: .fixed), at: 0) }
        #expect(runtime.owned == [0])
        hardware.failRestore = false
        runtime.tick(at: 20)
        #expect(runtime.owned.isEmpty && hardware.reading.hardwareMode == 0)
    }
    @Test("未知风扇不产生任何硬件写入")
    func unknownFan() {
        let hardware = FanFixtureDriver()
        let runtime = FanRuntime(hardware: hardware)
        #expect(throws: FanFailure.self) { try runtime.configure(fanID: 99, profile: .init(mode: .fixed), at: 0) }
        #expect(hardware.writes.isEmpty && hardware.restored.isEmpty)
    }
    @Test("外部改变目标或模式时停止调速，不循环争抢")
    func externalControl() throws {
        for mode in [0, 1] {
            let hardware = FanFixtureDriver()
            let runtime = FanRuntime(hardware: hardware)
            try runtime.configure(fanID: 0, profile: .init(mode: .fixed, rpm: 2800), at: 0)
            hardware.reading.hardwareMode = mode
            hardware.reading.targetRPM = 3400
            runtime.tick(at: 2)
            runtime.tick(at: 4)
            #expect(hardware.writes == [2800] && hardware.restored == [0])
            #expect(runtime.owned.isEmpty && runtime.profiles.isEmpty)
        }
    }
    @Test("稳定后的细小温度波动不反复写入，显示保留原始热点")
    func smallFluctuations() throws {
        let hardware = FanFixtureDriver()
        let runtime = FanRuntime(hardware: hardware)
        try activate(runtime)
        let count = hardware.writes.count
        for time in stride(from: 42.0, through: 80, by: 2) {
            hardware.reference = Int(time).isMultiple(of: 4) ? 94.9 : 95.1
            runtime.renew(at: time)
            runtime.tick(at: time)
        }
        #expect(hardware.writes.count == count && hardware.restored.isEmpty)
        #expect(try runtime.snapshot().temperature == hardware.temperature)
    }
    @Test("不到一百转的全速差额仍写到上限")
    func fullSpeedWithinDeadband() throws {
        let hardware = FanFixtureDriver()
        hardware.reference = 94.6
        let runtime = FanRuntime(hardware: hardware)
        try activate(runtime)
        #expect((hardware.writes.last ?? 0) > 4800 && (hardware.writes.last ?? 5000) < 4900)
        hardware.reference = 110
        advance(runtime, from: 42, through: 60)
        #expect(hardware.writes.last == 4900)
    }
    @Test("切换预设或从固定回增强重新等待，不继承旧高转状态")
    func resetCurveState() throws {
        let hardware = FanFixtureDriver()
        let runtime = FanRuntime(hardware: hardware)
        try activate(runtime)
        try runtime.configure(fanID: 0, profile: .init(mode: .fixed, rpm: 1800), at: 42)
        try runtime.configure(fanID: 0, profile: FanCurvePreset.cooling.profile, at: 44)
        let count = hardware.writes.count
        #expect(hardware.reading.hardwareMode == 0 && runtime.owned.isEmpty)
        advance(runtime, from: 46, through: 46)
        #expect(hardware.writes.count == count)
        advance(runtime, from: 48, through: 70)
        #expect(hardware.reading.hardwareMode == 1)
        try runtime.configure(fanID: 0, profile: .init(mode: .system), at: 72)
        #expect(runtime.profiles.isEmpty && runtime.owned.isEmpty)
    }
}
