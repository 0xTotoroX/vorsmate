import Combine
// [INPUT]: 纯内存风扇驱动和保存回调，不接触 SMC、系统授权或真实助手。
// [OUTPUT]: 四项选择的旧配置兼容、跨实例恢复、睡眠 / 唤醒、停用竞态与安静轮询回归。
// [POS]: FanModel 的真实生命周期测试；硬件规则另由 FanTests 覆盖。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateFan

@testable import Vorsmate

@Suite("风扇模型恢复")
@MainActor
struct FanModelTests {
    @Test("四项并列选择保存原有配置格式，均衡与增强能直接切换")
    func parallelChoices() async throws {
        var saved: [Int: FanProfile] = [:]
        let driver = FanMock()
        let model = FanModel(preview: true, driver: driver, persist: { saved = $0 })
        model.activate()
        await model.waitForOperations()
        for choice in [FanControlChoice.custom, .balanced, .enhanced, .automatic] {
            model.configure(id: 0, profile: choice.profile(rpm: 2800))
            await model.waitForOperations()
            let decoded = try JSONDecoder().decode(
                [Int: FanProfile].self, from: JSONEncoder().encode(saved))
            let profile = decoded[0] ?? FanProfile()
            #expect(FanControlChoice(profile: profile) == choice)
            #expect(model.snapshot.profiles == decoded)
            switch choice {
            case .automatic: #expect(decoded.isEmpty)
            case .balanced: #expect(profile == FanCurvePreset.balanced.profile)
            case .enhanced: #expect(profile == FanCurvePreset.cooling.profile)
            case .custom: #expect(profile == FanProfile(mode: .fixed, rpm: 2800))
            }
        }
        model.stop()
        await model.waitForOperations()
        let legacyCurve = FanProfile(mode: .curve, rampStart: 55, fullSpeed: 80)
        var legacySaves = 0
        let restored = FanModel(
            preview: true, savedProfiles: [0: legacyCurve], driver: driver,
            persist: { _ in legacySaves += 1 })
        restored.activate()
        await restored.waitForOperations()
        #expect(FanControlChoice(profile: restored.snapshot.profiles[0] ?? FanProfile()) == .custom)
        #expect(restored.snapshot.profiles[0] == legacyCurve)
        #expect(restored.savedProfiles[0] == legacyCurve)
        #expect(legacySaves == 0)
        restored.stop()
        await restored.waitForOperations()
    }
    @Test(
        "固定和两档增强保存，跨实例与唤醒自动恢复",
        arguments: [
            FanProfile(mode: .fixed, rpm: 2800), FanCurvePreset.balanced.profile, FanCurvePreset.cooling.profile,
        ])
    func restoration(profile: FanProfile) async {
        var saved: [Int: FanProfile] = [:]
        let driver = FanMock()
        let first = FanModel(preview: true, driver: driver, persist: { saved = $0 })
        first.activate()
        await first.waitForOperations()
        first.configure(id: 0, profile: profile)
        await first.waitForOperations()
        #expect(saved == [0: profile])
        first.stop()
        await first.waitForOperations()
        #expect(driver.snapshot.profiles.isEmpty)
        let second = FanModel(preview: true, savedProfiles: saved, driver: driver, persist: { saved = $0 })
        second.activate()
        await second.waitForOperations()
        #expect(second.snapshot.profiles == [0: profile])
        #expect(second.polling)
        second.willSleep()
        await second.waitForOperations()
        #expect(driver.snapshot.profiles.isEmpty)
        #expect(saved == [0: profile])
        #expect(!second.polling)
        second.didWake()
        await second.waitForOperations()
        #expect(driver.snapshot.profiles == [0: profile])
        second.configure(id: 0, profile: FanProfile())
        await second.waitForOperations()
        #expect(saved.isEmpty)
        #expect(!second.polling)
        second.stop()
        await second.waitForOperations()
    }
    @Test("自动隐藏停轮询，显示立即刷新，停用不受唤醒影响")
    func idle() async {
        let driver = FanMock()
        let model = FanModel(preview: true, driver: driver)
        model.activate()
        await model.waitForOperations()
        #expect(!model.polling)
        let count = driver.actions.count
        model.setPanelVisible(true)
        await model.waitForOperations()
        #expect(model.polling)
        #expect(driver.actions.count > count)
        model.setPanelVisible(false)
        #expect(!model.polling)
        model.stop()
        await model.waitForOperations()
        let stopped = driver.actions.count
        model.didWake()
        model.refresh()
        await model.waitForOperations()
        #expect(driver.actions.count == stopped)
        model.activate()
        await model.waitForOperations()
        model.stop()
        await model.waitForOperations()
    }
    @Test("未授权或有其他工具时不恢复调速", arguments: [true, false])
    func unavailable(competitor: Bool) async {
        let driver = FanMock()
        driver.helperEnabled = competitor
        driver.competingApp = competitor ? "Other Fan App" : nil
        let model = FanModel(preview: false, savedProfiles: [0: FanProfile(mode: .fixed)], driver: driver)
        model.activate()
        await model.waitForOperations()
        #expect(!driver.actions.contains(.configure))
        #expect(model.savedProfiles.count == 1)
        model.stop()
        await model.waitForOperations()
    }
    @Test("配置在途时停用，迟到结果不覆盖状态，释放晚于配置；重新激活仍可恢复")
    func lateConfiguration() async {
        let driver = FanMock()
        let model = FanModel(preview: true, driver: driver)
        model.activate()
        await model.waitForOperations()
        driver.hold = true
        model.configure(id: 0, profile: FanProfile(mode: .fixed))
        for _ in 0..<30 { await Task.yield() }
        model.stop()
        model.activate()
        driver.resume()
        await model.waitForOperations()
        #expect(driver.actions.suffix(4) == [.configure, .release, .configure, .status])
        #expect(model.snapshot.profiles[0]?.mode == .fixed)
        model.stop()
        await model.waitForOperations()
    }
    @Test("一个已保存风扇失效不阻止其他风扇恢复，等待助手时显示待确认")
    func multipleFans() async {
        let driver = FanMock()
        driver.rejectedID = 0
        let saved = [0: FanProfile(mode: .fixed), 1: FanCurvePreset.balanced.profile]
        let model = FanModel(preview: true, savedProfiles: saved, driver: driver)
        model.activate()
        #expect(!model.controlConfirmed)
        await model.waitForOperations()
        #expect(model.snapshot.profiles[1] == saved[1])
        #expect(model.error != nil)
        #expect(model.savedProfiles == saved)
        model.stop()
        await model.waitForOperations()
    }
    @Test("写盘失败不下发命令也不改变保存档位")
    func persistenceFailure() async {
        let driver = FanMock()
        let model = FanModel(preview: true, driver: driver, persist: { _ in throw CocoaError(.fileWriteUnknown) })
        model.activate()
        await model.waitForOperations()
        model.configure(id: 0, profile: FanProfile(mode: .fixed))
        await model.waitForOperations()
        #expect(!driver.actions.contains(.configure))
        #expect(model.savedProfiles.isEmpty)
        #expect(model.error != nil)
        model.stop()
        await model.waitForOperations()
    }
    @Test("后台读数刷新不进入操作状态，重复刷新去重且不写配置")
    func quietRefresh() async {
        let driver = FanMock()
        var saves = 0
        let model = FanModel(preview: true, driver: driver, persist: { _ in saves += 1 })
        model.activate()
        await model.waitForOperations()
        var states: [Bool] = []
        let observation = model.$busy.dropFirst().sink { states.append($0) }
        for temperature in [79.0, 80.0, 81.0] {
            driver.snapshot.temperature = temperature
            driver.holdStatus = true
            let previous = driver.actions.count
            model.refresh()
            model.refresh()
            for _ in 0..<30 { await Task.yield() }
            #expect(driver.actions.count == previous + 1)
            #expect(!model.busy)
            #expect(model.controlConfirmed)
            #expect(states.isEmpty)
            driver.resumeStatus()
            await model.waitForOperations()
            #expect(model.snapshot.temperature == temperature)
            #expect(states.isEmpty)
        }
        #expect(saves == 0)
        observation.cancel()
        model.stop()
        await model.waitForOperations()
    }
    @Test("状态读取在途仍接受手动切档，旧回读不覆盖新选择")
    func configureDuringRefresh() async {
        let driver = FanMock()
        let model = FanModel(preview: true, savedProfiles: [0: FanCurvePreset.balanced.profile], driver: driver)
        model.activate()
        await model.waitForOperations()
        driver.holdStatus = true
        model.refresh()
        for _ in 0..<30 { await Task.yield() }
        #expect(!model.busy)
        model.configure(id: 0, profile: FanCurvePreset.cooling.profile)
        #expect(model.busy)
        #expect(model.savedProfiles[0] == FanCurvePreset.cooling.profile)
        driver.resumeStatus()
        await model.waitForOperations()
        #expect(driver.actions.suffix(2) == [.status, .configure])
        #expect(model.snapshot.profiles[0] == FanCurvePreset.cooling.profile)
        #expect(!model.busy)
        model.stop()
        await model.waitForOperations()
    }
    @Test("读取中停用与重新激活不会遗留刷新标记或接受迟到状态")
    func stopDuringRefresh() async {
        let driver = FanMock()
        let model = FanModel(preview: true, driver: driver)
        model.activate()
        await model.waitForOperations()
        driver.holdStatus = true
        model.refresh()
        for _ in 0..<30 { await Task.yield() }
        model.stop()
        model.activate()
        driver.resumeStatus()
        await model.waitForOperations()
        let count = driver.actions.count
        model.refresh()
        await model.waitForOperations()
        #expect(driver.actions.count == count + 1)
        #expect(!model.busy)
        model.stop()
        await model.waitForOperations()
    }
}

@MainActor
private final class FanMock: FanModelDriver {
    var helperEnabled = true
    var needsApproval = false
    var competingApp: String?
    var actions: [FanCommand.Action] = []
    var snapshot = FanSnapshot()
    var hold = false
    var holdStatus = false
    var rejectedID: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    private var statusContinuation: CheckedContinuation<Void, Never>?
    func read() throws -> FanSnapshot { snapshot }
    func request(_ command: FanCommand) async throws -> FanSnapshot {
        actions.append(command.action)
        if command.action == .status, holdStatus {
            let reading = snapshot
            await withCheckedContinuation { statusContinuation = $0 }
            return reading
        }
        if command.action == .configure, hold {
            await withCheckedContinuation { continuation = $0 }
        }
        if command.action == .configure, let id = command.fanID, let profile = command.profile {
            if rejectedID == id { throw FanFailure.unavailable }
            if profile.mode == .system {
                snapshot.profiles.removeValue(forKey: id)
            } else {
                snapshot.profiles[id] = profile
            }
        }
        if command.action == .release { snapshot.profiles = [:] }
        return snapshot
    }
    func resume() {
        hold = false
        continuation?.resume()
        continuation = nil
    }
    func resumeStatus() {
        holdStatus = false
        statusContinuation?.resume()
        statusContinuation = nil
    }
    func invalidate() {}
    func install() throws {}
    func uninstall() async throws {}
}
