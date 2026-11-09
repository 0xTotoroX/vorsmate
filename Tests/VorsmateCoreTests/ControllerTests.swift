// [INPUT]: ChannelController 与可控的内存 SourceDriver。
// [OUTPUT]: 切换回读、重试、竞争、暂停、保存失败的运行时行为验证。
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
    @Test("其他工具持续抢占时暂停，用户可重试")
    func conflict() {
        let driver = FakeDriver()
        driver.ignoresSelection = true
        var time: TimeInterval = 0
        let controller = ChannelController(
            channel: .audioInput, driver: driver, policy: driver.automatic, clock: { time })
        defer { controller.stop() }
        for second in 0...4 {
            time = Double(second)
            controller.refresh()
        }
        #expect(controller.suspended)
        #expect(driver.selections.count == 4)
        #expect(controller.snapshot.selectedID == "b")
        driver.ignoresSelection = false
        controller.retry()
        controller.refresh()
        #expect(!controller.suspended)
        #expect(controller.snapshot.selectedID == "a")
    }
    @Test("没有设备通知时，未生效或失败的写入仍会有界重试并暂停", arguments: [false, true])
    func retriesWithoutNotifications(failsSelection: Bool) async throws {
        let driver = FakeDriver()
        driver.ignoresSelection = true
        driver.failsSelection = failsSelection
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: driver.automatic)
        defer { controller.stop() }
        controller.start()
        for _ in 0..<60 {
            if controller.suspended { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.suspended)
        #expect(driver.selections.count == 4)
        #expect(controller.snapshot.selectedID == "b")
        #expect(!controller.pending)
        #expect(controller.error != nil)
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
    @Test("驱动拒绝切换时显示错误并保留真实选择")
    func selectionFailure() {
        let driver = FakeDriver()
        driver.failsSelection = true
        let controller = ChannelController(channel: .audioInput, driver: driver, policy: driver.automatic)
        defer { controller.stop() }
        controller.refresh()
        #expect(controller.snapshot.selectedID == "b")
        #expect(controller.error != nil)
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
