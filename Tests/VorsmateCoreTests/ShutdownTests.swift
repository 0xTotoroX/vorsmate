// [INPUT]: 可手动推进的时钟与记录动作的 ShutdownDriver 替身。
// [OUTPUT]: 菜单栏五秒倒计时、收起继续执行、应用退出回读、取消、提交阶段、防重、排除与错误流程测试。
// [POS]: 关机安全回归，绝不创建真实驱动或调用系统动作。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateSystem

@Suite("一键关机安全流程")
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
        #expect(controller.status == "准备\(action.title)")
        #expect(controller.menuBarTitle == "5 秒后\(action.title)")
        for remaining in stride(from: 4, through: 1, by: -1) {
            await clock.advance()
            #expect(controller.countdown == remaining)
            #expect(controller.status == "准备\(action.title)")
            #expect(controller.menuBarTitle == "\(remaining) 秒后\(action.title)")
        }
        await clock.advance()
        #expect(controller.countdown == nil)
        #expect(driver.events == ["quit:close"])
        #expect(controller.executing)
        #expect(controller.status == "正在退出应用")
        #expect(controller.menuBarTitle == "正在退出应用")
        await clock.advance()
        await settle()
        #expect(driver.events == ["quit:close", "preference", "force:close", action.rawValue])
        #expect(controller.message == "已完成模拟\(action.title)")
        #expect(controller.pendingAction == nil)
        #expect(controller.menuBarTitle == nil)
        controller.deactivate()
    }
    @Test("取消和停用在任意秒均不执行动作", arguments: ["cancel", "stop"], Array(0..<5))
    func cancellation(mode: String, seconds: Int) async {
        let clock = ShutdownClock()
        let driver = ShutdownMock()
        let controller = ShutdownController(driver: driver, sleep: { try await clock.sleep($0) })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.shutdown)
        for _ in 0..<seconds { await clock.advance() }
        if mode == "cancel" { controller.cancel() }
        if mode == "stop" { controller.deactivate() }
        await clock.advance()
        await settle()
        #expect(driver.events.isEmpty)
        #expect(controller.countdown == nil)
        #expect(controller.message == "已取消关机")
        controller.deactivate()
    }
    @Test("倒计时或退出应用期间收起面板仍继续完成动作", arguments: [false, true])
    func hideContinuesFlow(duringExecuting: Bool) async {
        let clock = ShutdownClock()
        let driver = ShutdownMock()
        let controller = ShutdownController(driver: driver, sleep: { try await clock.sleep($0) })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.shutdown)
        if duringExecuting {
            for _ in 0..<5 { await clock.advance() }
            #expect(controller.executing && !controller.submitting)
        } else {
            await clock.advance()
            #expect(controller.countdown == 4)
        }
        controller.panelDidChangeVisibility(false)
        #expect(controller.pendingAction == .shutdown)
        #expect(controller.canCancel)
        for _ in 0..<(duringExecuting ? 1 : 5) { await clock.advance() }
        await settle()
        #expect(driver.events.last == "shutdown")
        #expect(controller.message == "已完成模拟关机")
        #expect(controller.pendingAction == nil)
        #expect(!controller.executing)
        controller.deactivate()
    }
    @Test("终端弹出退出确认，强制退出后等待原进程消失，超时明确报错", arguments: [false, true])
    func forcedExitReadback(exits: Bool) async {
        let clock = ShutdownClock()
        let driver = ShutdownMock()
        let terminal = RunningAppItem(bundleID: "com.apple.Terminal", name: "终端", pids: [8])
        driver.apps = [terminal]
        driver.forceCloses = false
        let controller = ShutdownController(driver: driver, sleep: { try await clock.sleep($0) })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.shutdown)
        for _ in 0..<6 { await clock.advance() }
        #expect(driver.events == ["quit:com.apple.Terminal", "preference", "force:com.apple.Terminal"])
        #expect(controller.executing && !controller.submitting)
        let reopenedTerminal = RunningAppItem(bundleID: terminal.id, name: terminal.name, pids: [9])
        if exits { driver.apps = [reopenedTerminal] }
        for _ in 0..<(exits ? 1 : ShutdownController.forceExitPollAttempts) { await clock.advance() }
        if exits {
            #expect(driver.events.last == "shutdown")
            #expect(controller.message == "已完成模拟关机")
            #expect(controller.apps == [reopenedTerminal])
        } else {
            #expect(!driver.events.contains("shutdown"))
            #expect(controller.error == "强制退出后，「终端」仍在运行，已停止关机。")
        }
        #expect(!controller.executing)
    }
    @Test("菜单栏状态格式化覆盖倒计时、退出应用、提交与空闲")
    func menuBarFormatting() {
        #expect(
            ShutdownStatusFormatter.menuBarTitle(countdown: nil, action: nil, executing: false, submitting: false)
                == nil)
        #expect(
            ShutdownStatusFormatter.menuBarTooltip(countdown: nil, action: nil, executing: false, submitting: false)
                == nil)
        for seconds in 1...5 {
            #expect(
                ShutdownStatusFormatter.menuBarTitle(
                    countdown: seconds, action: .shutdown, executing: false, submitting: false)
                    == "\(seconds) 秒后关机")
            #expect(
                ShutdownStatusFormatter.menuBarTooltip(
                    countdown: seconds, action: .restart, executing: false, submitting: false)
                    == "\(seconds) 秒后重启 · 右键取消")
        }
        #expect(
            ShutdownStatusFormatter.menuBarTitle(countdown: nil, action: .shutdown, executing: true, submitting: false)
                == "正在退出应用")
        #expect(
            ShutdownStatusFormatter.menuBarTooltip(
                countdown: nil, action: .restart, executing: true, submitting: false) == "正在退出应用 · 右键取消重启")
        #expect(
            ShutdownStatusFormatter.menuBarTitle(countdown: nil, action: .shutdown, executing: true, submitting: true)
                == "正在关机")
        #expect(
            ShutdownStatusFormatter.menuBarTooltip(countdown: nil, action: .restart, executing: true, submitting: true)
                == "正在提交重启请求")
    }
    @Test("应用拒绝退出时停止系统动作并保留窗口恢复设置", arguments: [false, true])
    func gentle(disableReopenWindows: Bool) async {
        let driver = ShutdownMock()
        var policy = ShutdownPolicy()
        policy.forceCloseApps = false
        policy.disableReopenWindows = disableReopenWindows
        let controller = ShutdownController(driver: driver, policy: policy, sleep: { _ in })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.restart)
        await settle()
        #expect(driver.events == ["quit:close", "quit:keep"])
        #expect(controller.error?.contains("「文稿」") == true)
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
    @Test("批量选择只改目标集合，一次保存，保留离线应用排除项")
    func bulkSelection() {
        var policy = ShutdownPolicy()
        policy.excludedBundleIDs = ["offline", "keep"]
        var writes = 0
        let controller = ShutdownController(driver: ShutdownMock(), policy: policy, persist: { _ in writes += 1 })
        controller.setIncluded(false, ids: ["keep", "close"])
        #expect(controller.policy.excludedBundleIDs == ["keep", "close", "offline"])
        controller.setIncluded(false, ids: ["close"])
        #expect(writes == 1)
        controller.setIncluded(true, ids: ["keep"])
        #expect(controller.policy.excludedBundleIDs == ["close", "offline"])
        #expect(writes == 2)
    }

    @Test("倒计时锁定用户看到的进程，之后打开的应用不会被插件退出")
    func reviewedAppsOnly() async {
        let clock = ShutdownClock()
        let driver = ShutdownMock()
        let controller = ShutdownController(driver: driver, sleep: { try await clock.sleep($0) })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.restart)
        driver.apps.append(RunningAppItem(bundleID: "late", name: "新启动", pids: [4]))
        controller.refresh()
        #expect(!controller.apps.contains { $0.id == "late" })
        for _ in 0..<6 { await clock.advance() }
        await settle()
        #expect(!driver.events.contains("quit:late"))
        #expect(driver.events.last == "restart")
        #expect(controller.apps.contains { $0.id == "late" })
    }

    @Test("系统已接收请求后，收起再打开不能重复提交")
    func pendingReceipt() async {
        let driver = ShutdownMock()
        driver.waitForReceipt = true
        let controller = ShutdownController(driver: driver, sleep: { _ in })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.shutdown)
        await settle()
        #expect(driver.receipt != nil)
        #expect(controller.submitting)
        #expect(controller.status == "正在提交关机请求")
        controller.panelDidChangeVisibility(false)
        controller.panelDidChangeVisibility(true)
        controller.start(.restart)
        #expect(controller.executing && controller.pendingAction == .shutdown)
        driver.receipt?.resume()
        await settle()
        #expect(!controller.executing)
        #expect(!controller.submitting)
        #expect(controller.message == "已完成模拟关机")
        #expect(driver.events.filter { $0 == "shutdown" || $0 == "restart" } == ["shutdown"])
    }
    @Test("取消后立即显示倒计时期间新打开的应用")
    func refreshAfterCancel() {
        let driver = ShutdownMock()
        let controller = ShutdownController(driver: driver)
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.shutdown)
        driver.apps.append(RunningAppItem(bundleID: "late", name: "新启动", pids: [4]))
        controller.refresh()
        #expect(controller.appCount == 2)
        controller.cancel()
        #expect(controller.appCount == 3)
        #expect(driver.events.isEmpty)
    }
    @Test("System Events 错误文案区分授权拒绝与一般失败", arguments: ShutdownAction.allCases)
    func appleScriptErrorFormatting(action: ShutdownAction) {
        let denied = SystemShutdownDriver.appleScriptErrorMessage(code: -1743, detail: "Not authorized", action: action)
        #expect(denied.contains("未获授权控制 System Events"))
        #expect(denied.contains("自动化"))
        let failed = SystemShutdownDriver.appleScriptErrorMessage(code: -1700, detail: "Timeout", action: action)
        #expect(failed == "系统未接受\(action.title)：Timeout")
    }
    @Test("系统动作前置准备期间可取消并触发恢复，准备或执行失败也触发恢复")
    func prepareAndRecoverHooks() async {
        // 1. 准备阶段挂起时允许 cancel() 并回调 recoverPreparedAction，不进入 submitting 或 execute
        let clock = ShutdownClock()
        let driver = ShutdownMock()
        var recoverCount = 0
        let controller = ShutdownController(
            driver: driver,
            sleep: { _ in },
            prepareSystemAction: { try await clock.sleep(.seconds(1)) },
            recoverPreparedAction: { recoverCount += 1 })
        controller.activate()
        controller.panelDidChangeVisibility(true)
        controller.start(.shutdown)
        for _ in 0..<100 where clock.waiting == false { await Task.yield() }
        #expect(!controller.submitting)
        #expect(controller.canCancel)
        controller.cancel()
        await settle()
        #expect(recoverCount == 1)
        #expect(!driver.events.contains("shutdown"))
        #expect(controller.message == "已取消关机")

        // 2. prepareSystemAction 抛错时触发恢复并暴露错误
        let failPrepareDriver = ShutdownMock()
        var failPrepareRecover = 0
        let failPrepare = ShutdownController(
            driver: failPrepareDriver,
            sleep: { _ in },
            prepareSystemAction: { throw CocoaError(.fileWriteNoPermission) },
            recoverPreparedAction: { failPrepareRecover += 1 })
        failPrepare.activate()
        failPrepare.panelDidChangeVisibility(true)
        failPrepare.start(.restart)
        await settle()
        #expect(failPrepareRecover == 1)
        #expect(!failPrepareDriver.events.contains("restart"))
        #expect(failPrepare.error != nil)

        // 3. prepareSystemAction 成功后 driver.execute 失败也触发恢复
        let failExecuteDriver = ShutdownMock()
        failExecuteDriver.fails = true
        var failExecuteRecover = 0
        let failExecute = ShutdownController(
            driver: failExecuteDriver,
            sleep: { _ in },
            prepareSystemAction: {},
            recoverPreparedAction: { failExecuteRecover += 1 })
        failExecute.activate()
        failExecute.panelDidChangeVisibility(true)
        failExecute.start(.shutdown)
        await settle()
        #expect(failExecuteRecover == 1)
        #expect(failExecuteDriver.events.contains("shutdown"))
        #expect(failExecute.error != nil)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor
private final class ShutdownClock {
    private var continuation: CheckedContinuation<Void, any Error>?
    var waiting: Bool { continuation != nil }
    func sleep(_ duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in
                let next = self.continuation
                self.continuation = nil
                next?.resume(throwing: CancellationError())
            }
        }
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
    var forceCloses = true
    var fails = false
    var waitForReceipt = false
    var receipt: CheckedContinuation<Void, Never>?
    var apps = [
        RunningAppItem(bundleID: "close", name: "文稿", pids: [1, 2]),
        RunningAppItem(bundleID: "keep", name: "保留", pids: [3]),
    ]
    func runningApps() -> [RunningAppItem] { apps }
    func disableReopenWindows() throws { events.append("preference") }
    func terminate(_ app: RunningAppItem, force: Bool) {
        events.append("\(force ? "force" : "quit"):\(app.id)")
        if force && forceCloses { apps.removeAll { $0 == app } }
    }
    func isRunning(_ app: RunningAppItem) -> Bool { !quits && apps.contains(app) }
    func execute(_ action: ShutdownAction) async throws {
        events.append(action.rawValue)
        if waitForReceipt { await withCheckedContinuation { receipt = $0 } }
        if fails { throw CocoaError(.executableLoad) }
    }
}
