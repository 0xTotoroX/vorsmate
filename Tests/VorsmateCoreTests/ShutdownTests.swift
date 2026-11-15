// [INPUT]: 可手动推进的时钟与记录动作的 ShutdownDriver 替身。
// [OUTPUT]: 五秒倒计时、重复触发、取消、排除、温和 / 强制退出和错误流程测试。
// [POS]: 关机安全回归，绝不创建真实驱动或调用系统动作。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateSystem

@Suite("一键下班安全流程")
@MainActor
struct ShutdownTests {
    @Test("完整倒计时、重新扫描、排除应用、先温和后强制且只执行一次", arguments: ShutdownAction.allCases)
    func execute(action: ShutdownAction) async {
        let clock = ShutdownClock()
        let driver = ShutdownMock()
        var policy = ShutdownPolicy()
        policy.excludedBundleIDs = ["keep"]
        let controller = ShutdownController(driver: driver, policy: policy, sleep: { try await clock.sleep($0) })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(action)
        controller.start(action)
        #expect(controller.countdown == 5)
        for remaining in stride(from: 4, through: 0, by: -1) {
            await clock.advance()
            if remaining > 0 { #expect(controller.countdown == remaining) }
        }
        #expect(driver.events == ["preference", "quit:close"])
        #expect(controller.executing)
        await clock.advance()
        await settle()
        #expect(driver.events == ["preference", "quit:close", "force:close", action.rawValue])
        #expect(controller.message == "已完成模拟\(action.title)")
        #expect(controller.pendingAction == nil)
        controller.deactivate()
    }
    @Test("取消、隐藏和停用在任意秒均不执行动作", arguments: ["cancel", "hide", "stop"], Array(0..<5))
    func cancellation(mode: String, seconds: Int) async {
        let clock = ShutdownClock()
        let driver = ShutdownMock()
        let controller = ShutdownController(driver: driver, sleep: { try await clock.sleep($0) })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.shutdown)
        for _ in 0..<seconds { await clock.advance() }
        if mode == "cancel" { controller.cancel() }
        if mode == "hide" { controller.panelDidChangeVisibility(false) }
        if mode == "stop" { controller.deactivate() }
        await clock.advance()
        await settle()
        #expect(driver.events.isEmpty)
        #expect(controller.countdown == nil)
        controller.deactivate()
    }
    @Test("关闭强制退出保留未保存应用并停止系统动作；关闭窗口偏好不写系统")
    func gentle() async {
        let driver = ShutdownMock()
        var policy = ShutdownPolicy()
        policy.forceCloseApps = false
        policy.disableReopenWindows = false
        let controller = ShutdownController(driver: driver, policy: policy, sleep: { _ in })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.restart)
        await settle()
        #expect(driver.events == ["quit:close", "quit:keep"])
        #expect(controller.error != nil)
        controller.deactivate()
    }
    @Test("自然退出后不强制退出；系统错误可见且可再次发起")
    func failure() async {
        let driver = ShutdownMock()
        driver.quits = true
        driver.fails = true
        let controller = ShutdownController(driver: driver, sleep: { _ in })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.shutdown)
        await settle()
        #expect(!driver.events.contains { $0.hasPrefix("force:") })
        #expect(controller.error != nil)
        #expect(!controller.executing)
        controller.deactivate()
    }
    @Test("排除列表持久化及保存失败保持原值")
    func policy() {
        var saved = ShutdownPolicy()
        let controller = ShutdownController(driver: ShutdownMock(), persist: { saved = $0 })
        controller.toggleExcluded("keep")
        #expect(saved.excludedBundleIDs == ["keep"])
        controller.toggleExcluded("keep")
        #expect(saved.excludedBundleIDs.isEmpty)
        let bad = ShutdownController(driver: ShutdownMock(), persist: { _ in throw CocoaError(.fileWriteUnknown) })
        bad.toggleExcluded("keep")
        #expect(bad.policy.excludedBundleIDs.isEmpty)
        #expect(bad.error != nil)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor
private final class ShutdownClock {
    private var continuation: CheckedContinuation<Void, any Error>?
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func advance() async {
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let next = continuation
        continuation = nil
        next?.resume()
        for _ in 0..<30 { await Task.yield() }
    }
}

@MainActor
private final class ShutdownMock: ShutdownDriver {
    let isPreview = true
    var events: [String] = []
    var quits = false
    var fails = false
    func runningApps() -> [RunningAppItem] {
        [
            RunningAppItem(bundleID: "close", name: "文稿", pids: [1, 2]),
            RunningAppItem(bundleID: "keep", name: "保留", pids: [3]),
        ]
    }
    func disableReopenWindows() throws { events.append("preference") }
    func terminate(_ app: RunningAppItem, force: Bool) { events.append("\(force ? "force" : "quit"):\(app.id)") }
    func isRunning(_ app: RunningAppItem) -> Bool { !quits }
    func execute(_ action: ShutdownAction) async throws {
        events.append(action.rawValue)
        if fails { throw CocoaError(.executableLoad) }
    }
}
