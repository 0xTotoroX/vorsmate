// [INPUT]: ChannelController 与可控的内存 SourceDriver。
// [OUTPUT]: 切换回读、冷却退避、自动恢复、持续异常及保存失败的运行时行为验证。
// [POS]: 驱动边界测试，不打开真实音频或输入法控制。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore

@testable import VorsmateSystem

@MainActor
private final class FakeDriver: SourceDriver {
    var snapshot = Snapshot(sources: [Source(id: "a", name: "A"), Source(id: "b", name: "B")], selectedID: "b")
    var selections: [String] = []
    var ignoresSelection = false
    var failsSelection = false
    var failsStart = false
    var failsRead = false
    var starts = 0
    var stops = 0
    var reads = 0
    var callbacks: [@MainActor () -> Void] = []
    func read() throws -> Snapshot {
        reads += 1
        if failsRead { throw SystemFailure.status("读取", -1) }
        return snapshot
    }
    func select(_ id: String) throws {
        selections.append(id)
        if failsSelection { throw SystemFailure.status("切换", -1) }
        if !ignoresSelection { snapshot.selectedID = id }
    }
    func start(onChange: @escaping @MainActor () -> Void) throws {
        starts += 1
        if failsStart { throw SystemFailure.status("监听", -1) }
        callbacks.append(onChange)
    }
    func stop() { stops += 1 }
    var automatic: SelectionPolicy { SelectionPolicy(enabled: true, priority: snapshot.sources) }
}

@Suite("运行时控制")
@MainActor
struct ControllerTests {
    @Test("拖动保存失败先回到原顺序，重试成功再提交；锁定不被排序改写")
    func dragPersistenceFailure() {
        let driver = FakeDriver()
        var failSave = true
        var policy = driver.automatic
        policy.lock("b")
        let controller = ChannelController(
            channel: .audioInput, driver: driver, policy: policy,
            persist: { _ in if failSave { throw CocoaError(.fileWriteNoPermission) } })
        defer { controller.stop() }
        controller.move(fromOffsets: [0], toOffset: 2)
        #expect(controller.policy == policy)
        #expect(controller.error != nil)
        #expect(driver.selections.isEmpty)
        failSave = false
        controller.retry()
        #expect(controller.policy.priority.map(\.id) == ["b", "a"])
        #expect(controller.policy.lockedID == "b")
        #expect(controller.error == nil)
        #expect(driver.selections.isEmpty)
    }
    @Test("拖动松手一次保存并按新优先级选择，各通道独立", arguments: Channel.allCases)
    func dragPriority(channel: Channel) throws {
        let driver = FakeDriver()
        var saved: [SelectionPolicy] = []
        let controller = ChannelController(
            channel: channel, driver: driver, policy: driver.automatic, persist: { saved.append($0) })
        defer { controller.stop() }
        controller.move(fromOffsets: [0], toOffset: 2)
        #expect(saved.count == 1)
        #expect(saved[0].priority.map(\.id) == ["b", "a"])
        #expect(controller.policy.lockedID == nil)
        #expect(driver.selections.isEmpty)
        controller.move(fromOffsets: [0], toOffset: 0)
        #expect(saved.count == 1)
        controller.move(fromOffsets: [0], toOffset: 2)
        #expect(saved.count == 2)
        #expect(driver.selections == ["a"])
        var preferences = Preferences()
        preferences[channel] = saved.last!
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded[channel].priority.map(\.id) == ["a", "b"])
        for other in Channel.allCases where other != channel {
            #expect(decoded[other] == Preferences()[other])
        }
    }
    @Test("接收器仍在线时依据发射器连接切换和回退，静音不增加切换")
    func wirelessReadiness() {
        let driver = FakeDriver()
        driver.snapshot.availability["a"] = .waitingForTransmitter
        var time: TimeInterval = 0
        let controller = ChannelController(
            channel: .audioInput, driver: driver, policy: driver.automatic, clock: { time })
        defer { controller.stop() }
        controller.start()
        #expect(driver.selections.isEmpty)
        driver.snapshot.availability["a"] = .ready
        time = 2
        controller.refresh()
        controller.refresh()
        #expect(driver.snapshot.selectedID == "a")
        for _ in 0..<10 {
            time += 1
            controller.refresh()
        }
        #expect(driver.selections == ["a"])
        driver.snapshot.availability["a"] = .waitingForTransmitter
        controller.refresh()
        controller.refresh()
        #expect(driver.snapshot.selectedID == "b")
        #expect(!controller.recovering)
        // 未就绪设备仍可选择锁定；先用备用，连接后恢复原锁定。
        controller.select("a")
        #expect(controller.policy.lockedID == "a")
        #expect(controller.waitingName == "A")
        time += 2
        driver.snapshot.availability["a"] = .ready
        controller.refresh()
        controller.refresh()
        #expect(driver.snapshot.selectedID == "a")
        #expect(controller.waitingName == nil)
        #expect(driver.selections == ["a", "b", "a"])
        controller.select("b")
        controller.refresh()
        #expect(driver.snapshot.selectedID == "b")
        #expect(controller.policy.lockedID == "b")
    }
    @Test("写入后回读真实结果，不重复切换")
    func readback() {
        let driver = FakeDriver()
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: driver.automatic)
        defer { controller.stop() }
        controller.refresh()
        #expect(driver.selections == ["a"])
        #expect(controller.snapshot.selectedID == "b")
        controller.refresh()
        #expect(controller.snapshot.selectedID == "a")
        #expect(!controller.pending)
        #expect(driver.selections == ["a"])
    }
    @Test("手动选择保持锁定，恢复自动后回到最高优先级")
    func manualThenAutomatic() {
        let driver = FakeDriver()
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: driver.automatic)
        defer { controller.stop() }
        controller.refresh()
        controller.select("b")
        controller.refresh()
        #expect(controller.policy.lockedID == "b")
        #expect(controller.snapshot.selectedID == "b")
        controller.setMode("auto")
        controller.refresh()
        #expect(controller.policy.lockedID == nil)
        #expect(controller.snapshot.selectedID == "a")
    }
    @Test("关闭管理停止监听，不改变系统当前选择")
    func pause() {
        let driver = FakeDriver()
        let controller = ChannelController(channel: .inputSource, driver: driver)
        defer { controller.stop() }
        controller.start()
        #expect(driver.starts == 0)
        #expect(driver.selections.isEmpty)
        controller.setMode("auto")
        #expect(driver.starts == 1)
        controller.setMode("off")
        driver.snapshot.selectedID = "b"
        controller.refresh()
        #expect(driver.snapshot.selectedID == "b")
        #expect(driver.stops > 0)
    }
    @Test("设备失联回退，接回后恢复锁定")
    func reconnect() {
        let driver = FakeDriver()
        var time: TimeInterval = 0
        var policy = driver.automatic
        policy.lock("a")
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: policy, clock: { time })
        defer { controller.stop() }
        controller.refresh()
        controller.refresh()
        driver.snapshot = Snapshot(sources: [Source(id: "b", name: "B")], selectedID: "b")
        time = 2
        controller.refresh()
        #expect(controller.waitingName == "A")
        driver.snapshot.sources.append(Source(id: "a", name: "A"))
        time = 4
        controller.refresh()
        controller.refresh()
        #expect(controller.snapshot.selectedID == "a")
        #expect(controller.waitingName == nil)
    }
    @Test("短暂异常先冷却，回读正常后自动恢复锁定", arguments: Channel.allCases)
    func conflict(channel: Channel) {
        let driver = FakeDriver()
        driver.ignoresSelection = true
        var time: TimeInterval = 0
        var policy = driver.automatic
        policy.lock("a")
        let controller = ChannelController(
            channel: channel, driver: driver, policy: policy, clock: { time })
        defer { controller.stop() }
        controller.start()
        for second in 0...4 {
            time = Double(second)
            controller.refresh()
        }
        #expect(controller.recovering)
        #expect(!controller.suspended)
        #expect(controller.error == nil)
        #expect(driver.selections.count == 4)
        #expect(driver.stops == 0)
        #expect(controller.snapshot.selectedID == "b")
        time = 8
        controller.refresh()
        #expect(driver.selections.count == 4)
        driver.snapshot.selectedID = "a"
        controller.refresh()
        #expect(!controller.recovering)
        #expect(controller.error == nil)
        #expect(controller.policy.lockedID == "a")
        #expect(controller.mode == "locked")
        #expect(driver.selections.count == 4)
        // 恢复后仍执行原锁定，而不是只把提示隐藏。
        driver.ignoresSelection = false
        driver.snapshot.selectedID = "b"
        time = 10
        controller.refresh()
        controller.refresh()
        #expect(!controller.suspended)
        #expect(driver.selections.count == 5)
        #expect(controller.snapshot.selectedID == "a")
    }
    @Test("没有设备通知也会冷却后复查并恢复，不需要手动重试", arguments: [false, true])
    func retriesWithoutNotifications(failsSelection: Bool) async throws {
        let driver = FakeDriver()
        driver.ignoresSelection = true
        driver.failsSelection = failsSelection
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: driver.automatic)
        defer { controller.stop() }
        controller.start()
        for _ in 0..<60 {
            if controller.recovering { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.recovering)
        #expect(!controller.suspended)
        #expect(driver.selections.count == 4)
        #expect(controller.snapshot.selectedID == "b")
        #expect(!controller.pending)
        #expect(controller.error == nil)
        driver.ignoresSelection = false
        driver.failsSelection = false
        // 不调用 refresh、不发送通知，真实定时任务必须自行完成恢复。
        for _ in 0..<65 {
            if !controller.recovering { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!controller.recovering)
        #expect(controller.snapshot.selectedID == "a")
        #expect(controller.error == nil)
        #expect(driver.selections.count == 5)
    }
    @Test("持续异常才提示，后续单次重试间隔封顶三十秒")
    func persistentConflict() {
        let driver = FakeDriver()
        driver.ignoresSelection = true
        var time: TimeInterval = 0
        let controller = ChannelController(
            channel: .inputSource, driver: driver, policy: driver.automatic, clock: { time })
        defer { controller.stop() }
        for second in 0...4 {
            time = Double(second)
            controller.refresh()
        }
        for (second, count) in [(8.9, 4), (9.0, 5), (18.9, 5), (19.0, 6), (33.9, 6)] {
            time = second
            controller.refresh()
            #expect(driver.selections.count == count)
            #expect(controller.error == nil)
        }
        time = 34
        controller.refresh()
        #expect(controller.error?.contains("自动重试") == true)
        #expect(!controller.suspended)
        for (second, count) in [(39.0, 7), (39.1, 7), (68.9, 7), (69.0, 8), (98.9, 8), (99.0, 9)] {
            time = second
            // 重复通知不能缩短冷却或多次写入。
            for _ in 0..<5 { controller.refresh() }
            #expect(driver.selections.count == count)
        }
        driver.snapshot.selectedID = "a"
        controller.refresh()
        #expect(!controller.recovering)
        #expect(controller.error == nil)
    }
    @Test("冷却期间手动重试或改选立即生效", arguments: [false, true])
    func manualRecovery(selectDifferent: Bool) {
        let driver = FakeDriver()
        driver.ignoresSelection = true
        var time: TimeInterval = 0
        let controller = ChannelController(
            channel: .inputSource, driver: driver, policy: driver.automatic, clock: { time })
        defer { controller.stop() }
        for second in 0...4 {
            time = Double(second)
            controller.refresh()
        }
        driver.ignoresSelection = false
        if selectDifferent { controller.select("b") } else { controller.retry() }
        controller.refresh()
        #expect(!controller.recovering)
        #expect(controller.error == nil)
        #expect(controller.snapshot.selectedID == (selectDifferent ? "b" : "a"))
        #expect(driver.selections.count == (selectDifferent ? 4 : 5))
    }
    @Test("关闭管理或退出取消冷却，迟到通知和复查不会重新切换", arguments: [false, true])
    func stopDuringRecovery(stopEntirely: Bool) async throws {
        let driver = FakeDriver()
        driver.ignoresSelection = true
        var time: TimeInterval = 0
        let controller = ChannelController(
            channel: .inputSource, driver: driver, policy: driver.automatic, clock: { time })
        defer { controller.stop() }
        controller.start()
        for second in 0...4 {
            time = Double(second)
            controller.refresh()
        }
        if stopEntirely { controller.stop() } else { controller.setMode("off") }
        let reads = driver.reads
        time = 40
        driver.callbacks.first?()
        try await Task.sleep(for: .milliseconds(5300))
        #expect(!controller.recovering)
        #expect(controller.error == nil)
        #expect(driver.reads == reads)
        #expect(driver.selections.count == 4)
    }
    @Test("切换成功后反复被切走仍受限频保护")
    func successfulButRepeatedSwitches() {
        let driver = FakeDriver()
        var time: TimeInterval = 0
        let controller = ChannelController(
            channel: .inputSource, driver: driver, policy: driver.automatic, clock: { time })
        defer { controller.stop() }
        for second in 0...4 {
            time = Double(second)
            driver.snapshot.selectedID = "b"
            controller.refresh()
            controller.refresh()
        }
        #expect(driver.selections.count == 4)
        #expect(controller.recovering)
        #expect(controller.error == nil)
    }
    @Test("读取暂时失败不立即报警，持续失败才提示且可自动恢复")
    func recoverReadFailureWhileManaging() {
        let driver = FakeDriver()
        driver.failsRead = true
        var time: TimeInterval = 0
        let controller = ChannelController(
            channel: .inputSource, driver: driver, policy: driver.automatic, clock: { time })
        defer { controller.stop() }
        controller.start()
        #expect(controller.recovering)
        #expect(controller.error == nil)
        time = 30
        controller.refresh()
        #expect(controller.error != nil)
        #expect(driver.selections.isEmpty)
        driver.failsRead = false
        driver.snapshot.selectedID = "a"
        controller.refresh(readOnly: true)
        #expect(controller.recovering)
        controller.refresh()
        #expect(!controller.recovering)
        #expect(controller.error == nil)
    }
    @Test("保存失败不执行用户要求的系统切换")
    func persistenceFailure() {
        let driver = FakeDriver()
        let policy = SelectionPolicy(priority: driver.snapshot.sources)
        let controller = ChannelController(
            channel: .audioInput, driver: driver, policy: policy,
            persist: { _ in throw CocoaError(.fileWriteNoPermission) })
        defer { controller.stop() }
        controller.refresh()
        controller.select("a")
        #expect(driver.selections.isEmpty)
        #expect(!controller.policy.enabled)
        #expect(controller.error != nil)
    }
    @Test("单次切换失败不立即报警，并保留真实选择")
    func selectionFailure() {
        let driver = FakeDriver()
        driver.failsSelection = true
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: driver.automatic)
        defer { controller.stop() }
        controller.refresh()
        #expect(controller.snapshot.selectedID == "b")
        #expect(controller.error == nil)
        #expect(!controller.pending)
    }
    @Test("监听失败明确暂停，避免假装继续管理")
    func listenerFailure() {
        let driver = FakeDriver()
        driver.failsStart = true
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: driver.automatic)
        defer { controller.stop() }
        controller.start()
        #expect(controller.suspended)
        #expect(controller.error != nil)
        #expect(!controller.pending)
        #expect(driver.selections.isEmpty)
        #expect(controller.snapshot.selectedID == "b")
    }
    @Test("停用后迟到的通知不会重新读取或切换")
    func ignoresLateNotifications() async throws {
        let driver = FakeDriver()
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: driver.automatic)
        defer { controller.stop() }
        controller.start()
        controller.setMode("off")
        let reads = driver.reads
        driver.callbacks.first?()
        try await Task.sleep(for: .milliseconds(250))
        #expect(driver.reads == reads)
        #expect(driver.selections == ["a"])
    }
    @Test("保存失败的手动锁定可重试，回读不掩盖保存错误")
    func retryFailedSave() {
        let driver = FakeDriver()
        var writable = false
        var saved: SelectionPolicy?
        let controller = ChannelController(
            channel: .audioInput, driver: driver,
            policy: SelectionPolicy(priority: driver.snapshot.sources),
            persist: {
                if !writable { throw CocoaError(.fileWriteNoPermission) }
                saved = $0
            })
        defer { controller.stop() }
        controller.refresh()
        controller.select("a")
        controller.refresh()
        #expect(controller.error != nil)
        #expect(driver.selections.isEmpty)
        writable = true
        controller.retry()
        controller.refresh()
        #expect(saved?.lockedID == "a")
        #expect(controller.snapshot.selectedID == "a")
        #expect(controller.error == nil)
    }
    @Test("关闭时的临时读取错误在成功刷新后消失")
    func recoverReadError() {
        let driver = FakeDriver()
        driver.failsRead = true
        let controller = ChannelController(channel: .audioInput, driver: driver)
        defer { controller.stop() }
        controller.refresh()
        #expect(controller.error != nil)
        driver.failsRead = false
        controller.refresh()
        #expect(controller.error == nil)
    }
    @Test("点击锁定使用此刻设备，不使用关闭期间的旧快照")
    func lockCurrentDevice() {
        let driver = FakeDriver()
        let controller = ChannelController(channel: .audioInput, driver: driver)
        defer { controller.stop() }
        controller.start()
        driver.snapshot.selectedID = "a"
        controller.setMode("locked")
        #expect(controller.policy.lockedID == "a")
        #expect(driver.selections.isEmpty)
    }
    @Test("只读刷新不保存或切换，重载有效配置后恢复管理")
    func readOnlyThenReload() {
        let driver = FakeDriver()
        var saved = false
        let controller = ChannelController(channel: .audioInput, driver: driver, persist: { _ in saved = true })
        defer { controller.stop() }
        controller.refresh(readOnly: true)
        #expect(controller.snapshot.selectedID == "b")
        #expect(!saved)
        #expect(driver.selections.isEmpty)
        controller.reload(driver.automatic)
        #expect(driver.starts == 1)
        #expect(driver.selections == ["a"])
    }
}
