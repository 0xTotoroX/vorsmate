// [INPUT]: 增强参考温度、确定性时间序列和系统当前转速。
// [OUTPUT]: 两档中负载差异、趋势提前量、尖峰忽略、升降速节奏及低温释放的行为验证。
// [POS]: 无硬件测试；不把核心热点混入参考温度。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Testing
import VorsmateCore

@Suite("增强散热平滑")
struct FanCurveTests {
    private let fan = FanReading(
        id: 0, actualRPM: 2000, targetRPM: 2000, minimumRPM: 1000, maximumRPM: 4900, hardwareMode: 0)
    private let profile = FanCurvePreset.balanced.profile

    @Test("中等持续负载下两档均实际增强，强冷有明显更高的稳定转速")
    func distinctModerateLoad() throws {
        var automatic = fan
        automatic.actualRPM = 1000
        automatic.targetRPM = 1000
        var settled: [Double] = []
        for preset in FanCurvePreset.allCases {
            var curve = FanCurveController()
            var target: Double?
            for time in stride(from: 0.0, through: 180, by: 2) {
                target = try curve.target(for: automatic, profile: preset.profile, temperature: 80, at: time)
            }
            settled.append(target ?? 1000)
        }
        #expect(abs(settled[0] - 2170) <= 100)
        #expect(abs(settled[1] - 3535) <= 100)
        #expect(settled[1] - settled[0] >= 1200)
    }

    @Test("选择增强不会立即接管，均衡比强冷等待更久")
    func sustainedConfirmation() throws {
        for preset in FanCurvePreset.allCases {
            var curve = FanCurveController()
            for time in stride(from: 0.0, to: preset.confirmationTime, by: 2) {
                #expect(try curve.target(for: fan, profile: preset.profile, temperature: 110, at: time) == nil)
            }
            #expect(
                try curve.target(for: fan, profile: preset.profile, temperature: 110, at: preset.confirmationTime)
                    == 2000)
        }
    }

    @Test("即使短暂超过全速点也不立即拉满")
    func shortSpike() throws {
        for preset in FanCurvePreset.allCases {
            var curve = FanCurveController()
            #expect(try curve.target(for: fan, profile: preset.profile, temperature: 65, at: 0) == nil)
            #expect(try curve.target(for: fan, profile: preset.profile, temperature: 115, at: 2) == nil)
            for time in stride(from: 4.0, through: 40, by: 2) {
                #expect(try curve.target(for: fan, profile: preset.profile, temperature: 65, at: time) == nil)
            }
        }
    }

    @Test("持续高温逐渐升到上限，均衡和强冷分别遵守加速上限")
    func sustainedHeat() throws {
        for preset in FanCurvePreset.allCases {
            var curve = FanCurveController()
            var previous = fan.actualRPM
            for time in stride(from: 0.0, through: 60, by: 2) {
                if let next = try curve.target(for: fan, profile: preset.profile, temperature: 110, at: time) {
                    #expect(next >= previous && next - previous <= (preset == .balanced ? 300.001 : 600.001))
                    previous = next
                }
            }
            #expect(previous == fan.maximumRPM)
        }
    }

    @Test("降温会打断接管计时，间歇尖峰不能凑成持续高温")
    func interruptedConfirmation() throws {
        var curve = FanCurveController()
        for time in stride(from: 0.0, through: 60, by: 2) {
            let temperature = Int(time).isMultiple(of: 8) ? 70.0 : 110.0
            #expect(try curve.target(for: fan, profile: profile, temperature: temperature, at: time) == nil)
        }
    }

    @Test("系统已要求更高转速时不接管，不以增强为名降低系统目标")
    func automaticFloor() throws {
        var faster = fan
        faster.actualRPM = 3900
        faster.targetRPM = 3900
        var curve = FanCurveController()
        for time in stride(from: 0.0, through: 60, by: 2) {
            #expect(try curve.target(for: faster, profile: profile, temperature: 85, at: time) == nil)
        }
        faster.targetRPM = 2300
        faster.actualRPM = 2400
        for time in stride(from: 62.0, through: 100, by: 2) {
            if let target = try curve.target(for: faster, profile: profile, temperature: 85, at: time) {
                #expect(target >= 2300 && target <= 2755)
            }
        }
    }

    @Test("两档持续冷却先保持再缓降，最后交还自动且不会立即抢回", arguments: FanCurvePreset.allCases)
    func coolingRelease(preset: FanCurvePreset) throws {
        let profile = preset.profile
        var curve = FanCurveController()
        for time in stride(from: 0.0, through: 60, by: 2) {
            _ = try curve.target(for: fan, profile: profile, temperature: 110, at: time)
        }
        var previous = 4900.0
        var released = false
        for time in stride(from: 62.0, through: 180, by: 2) {
            let target = try curve.target(for: fan, profile: profile, temperature: 65, at: time)
            if let target {
                #expect(!released)
                #expect(target <= previous && previous - target <= 200.001)
                if time <= 70 { #expect(target == 4900) }
                previous = target
            } else {
                released = true
            }
        }
        #expect(released)
        #expect(try curve.target(for: fan, profile: profile, temperature: 110, at: 182) == nil)
    }

    @Test("全速点以上的温度不拖长降速历史")
    func boundedHeatHistory() throws {
        var first = FanCurveController()
        var second = FanCurveController()
        for time in stride(from: 0.0, through: 60, by: 2) {
            _ = try first.target(for: fan, profile: profile, temperature: 105, at: time)
            _ = try second.target(for: fan, profile: profile, temperature: 120, at: time)
        }
        for time in stride(from: 62.0, through: 180, by: 2) {
            #expect(
                try first.target(for: fan, profile: profile, temperature: 65, at: time)
                    == second.target(for: fan, profile: profile, temperature: 65, at: time))
        }
    }

    @Test("停止采样后的一次高温不能证明持续高温")
    func samplingGap() throws {
        var curve = FanCurveController()
        #expect(try curve.target(for: fan, profile: profile, temperature: 110, at: 0) == nil)
        #expect(try curve.target(for: fan, profile: profile, temperature: 110, at: 30) == nil)
        for time in stride(from: 32.0, through: 36, by: 2) {
            #expect(try curve.target(for: fan, profile: profile, temperature: 110, at: time) == nil)
        }
        #expect(try curve.target(for: fan, profile: profile, temperature: 110, at: 38) == 2000)
    }

    @Test("系统原先已高转时不必降到最低起点才归还")
    func releaseToFasterAutomatic() throws {
        var automatic = fan
        automatic.actualRPM = 3000
        automatic.targetRPM = 3000
        var curve = FanCurveController()
        for time in stride(from: 0.0, through: 60, by: 2) {
            _ = try curve.target(for: automatic, profile: profile, temperature: 110, at: time)
        }
        var target: Double?
        for time in stride(from: 62.0, through: 180, by: 2) {
            target = try curve.target(for: automatic, profile: profile, temperature: 80, at: time)
        }
        #expect(target == nil)
    }

    @Test("无效参考温度不能被历史低温掩盖")
    func invalidTemperature() throws {
        for temperature: Double? in [nil, 0, .nan, .infinity, 130, 200] {
            var curve = FanCurveController()
            _ = try curve.target(for: fan, profile: profile, temperature: 80, at: 0)
            #expect(throws: FanFailure.self) {
                try curve.target(for: fan, profile: profile, temperature: temperature, at: 2)
            }
        }
    }

    @Test("重复时间不推进确认，时钟倒退和非法时间拒绝")
    func clockBoundaries() throws {
        var curve = FanCurveController()
        #expect(try curve.target(for: fan, profile: profile, temperature: 110, at: 10) == nil)
        for _ in 0..<20 { #expect(try curve.target(for: fan, profile: profile, temperature: 110, at: 10) == nil) }
        for time: Double in [9, .nan, .infinity] {
            #expect(throws: FanFailure.self) {
                try curve.target(for: fan, profile: profile, temperature: 110, at: time)
            }
        }
    }

    @Test("强冷对连续升温提前加速，但提前量受限，不因一帧温度变动全速")
    func risingTrend() throws {
        var automatic = fan
        automatic.actualRPM = 1000
        automatic.targetRPM = 1000
        let profile = FanCurvePreset.cooling.profile
        var curve = FanCurveController()
        for time in stride(from: 0.0, through: 180, by: 2) {
            _ = try curve.target(for: automatic, profile: profile, temperature: 80, at: time)
        }
        var target = 0.0
        for step in 1...5 {
            let temperature = 80 + Double(step)
            let next = try curve.target(
                for: automatic, profile: profile, temperature: temperature, at: 180 + Double(step) * 2)
            target = try #require(next)
            #expect(target <= (try profile.target(for: automatic, temperature: temperature + 4) ?? 1000))
        }
        #expect(target > (try profile.target(for: automatic, temperature: 85) ?? 0))
        #expect(target < automatic.maximumRPM)
        for time in stride(from: 192.0, through: 300, by: 2) {
            let next = try curve.target(for: automatic, profile: profile, temperature: 85, at: time)
            target = try #require(next)
        }
        #expect(abs(target - 4315) < 100)
    }

    @Test("稳定负载的小幅抖动与两秒冷却不会让转速来回跳")
    func stableLoad() throws {
        for preset in FanCurvePreset.allCases {
            var automatic = fan
            automatic.actualRPM = 1000
            automatic.targetRPM = 1000
            var curve = FanCurveController()
            var steady = 0.0
            for time in stride(from: 0.0, through: 180, by: 2) {
                steady = try curve.target(for: automatic, profile: preset.profile, temperature: 80, at: time) ?? 0
            }
            for time in stride(from: 182.0, through: 240, by: 2) {
                let temperature = Int(time).isMultiple(of: 4) ? 80.2 : 79.8
                #expect(
                    try curve.target(for: automatic, profile: preset.profile, temperature: temperature, at: time)
                        == steady)
            }
            #expect(try curve.target(for: automatic, profile: preset.profile, temperature: 55, at: 242) == steady)
            #expect(try curve.target(for: automatic, profile: preset.profile, temperature: 80, at: 244) == steady)
        }
    }
}
