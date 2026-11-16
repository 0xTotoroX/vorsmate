// [INPUT]: 实际更新模型 / 用户驱动、可推进等待器及 Sparkle 回调替身。
// [OUTPUT]: 截止时间、取消、重试、迟到回调隔离及安装关键阶段保护回归。
// [POS]: 更新流程行为测试，不请求网络、不打开窗口、不执行真实安装。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Sparkle
import Testing

@testable import Vorsmate

@Suite("更新截止与重试")
@MainActor
struct UpdateSessionTests {
    private func drain() async { for _ in 0..<40 { await Task.yield() } }

    @Test("开始回调之前卡住也会超时，重试创建新会话，旧回调不能改写界面")
    func checkTimeoutAndRetry() async {
        let clock = UpdateWaiter()
        var drivers: [UpdateUserDriver] = []
        let model = UpdateModel(
            enabled: true, scheduled: false, showsWindows: false, pause: { await clock.wait($0) },
            makeSession: {
                drivers.append($0)
                return FakeUpdateSession()
            })
        model.check()
        #expect(model.checking && !model.canCheck)
        await drain()
        clock.fire(0)
        await drain()
        #expect(!model.checking && model.canCheck)
        #expect(model.panel.model.primary == "重试")
        #expect(!model.panel.model.busy)
        model.panel.model.performPrimary()
        await drain()
        #expect(drivers.count == 2)
        #expect(model.checking)
        var cancelled = 0
        var acknowledged = 0
        drivers[0].showUserInitiatedUpdateCheck { cancelled += 1 }
        drivers[0].showUpdaterError(URLError(.timedOut)) { acknowledged += 1 }
        drivers[0].dismissUpdateInstallation()
        #expect(cancelled == 1 && acknowledged == 1)
        #expect(model.panel.model.busy)
        #expect(model.checking)
        drivers[1].showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: 1001)) {}
        #expect(!model.checking && model.canCheck)
        model.stop()
        clock.finish()
        await drain()
    }
    @Test("取消只执行一次，迟到的准备结果不能安装或留到退出时安装")
    func cancelAndLateReady() async {
        let clock = UpdateWaiter()
        let driver = UpdateUserDriver(showsWindows: false, pause: { await clock.wait($0) })
        driver.begin(manual: true)
        var cancellations = 0
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        driver.panel.model.performSecondary()
        driver.cancel()
        #expect(cancellations == 1)
        var choice: SPUUserUpdateChoice?
        driver.showReady { choice = $0 }
        #expect(choice == .skip)
        #expect(!driver.active)
        await drain()
        clock.finish()
        await drain()
    }
    @Test("下载有进展续期，零字节不续期，停滞后取消并提供重试")
    func stalledDownload() async {
        let clock = UpdateWaiter()
        let driver = UpdateUserDriver(showsWindows: false, pause: { await clock.wait($0) })
        driver.begin(manual: true)
        var cancelled = 0
        driver.showDownloadInitiated { cancelled += 1 }
        await drain()
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 25)
        await drain()
        clock.fire(0)
        await drain()
        #expect(driver.active)
        #expect(driver.panel.model.progress == 0.25)
        let count = clock.count
        driver.showDownloadDidReceiveData(ofLength: 0)
        await drain()
        #expect(clock.count == count)
        clock.fire(count - 1)
        await drain()
        #expect(!driver.active)
        #expect(cancelled == 1)
        #expect(driver.panel.model.primary == "重试")
        #expect(!driver.panel.model.busy)
        clock.finish()
        await drain()
    }
    @Test("后台失败不弹出错误，手动检查仍可重新开始")
    func quietBackground() async {
        let clock = UpdateWaiter()
        var drivers: [UpdateUserDriver] = []
        let model = UpdateModel(
            enabled: true, scheduled: false, showsWindows: false, pause: { await clock.wait($0) },
            makeSession: {
                drivers.append($0)
                return FakeUpdateSession()
            })
        model.check(manual: false)
        await drain()
        clock.fire(0)
        await drain()
        #expect(model.panel.model.primary == nil)
        #expect(!model.checking && model.canCheck)
        model.check()
        #expect(drivers.count == 2)
        #expect(model.panel.model.busy)
        model.stop()
        await drain()
        clock.finish()
        await drain()
    }
    @Test("错误立即确认框架回调，关窗与迟到关闭不清掉重试状态")
    func errorAcknowledgement() async {
        let clock = UpdateWaiter()
        let driver = UpdateUserDriver(showsWindows: false, pause: { await clock.wait($0) })
        driver.begin(manual: true)
        var acknowledgement = 0
        var cancelled = 0
        driver.showUserInitiatedUpdateCheck { cancelled += 1 }
        driver.showUpdaterError(NSError(domain: SUSparkleErrorDomain, code: 3001)) { acknowledgement += 1 }
        driver.dismissUpdateInstallation()
        #expect(acknowledgement == 1)
        #expect(cancelled == 0)
        #expect(driver.panel.model.title == UpdateFailure.invalidSignature.title)
        #expect(driver.panel.model.primary == "重试")
        driver.panel.model.close()
        #expect(acknowledgement == 1)
        await drain()
        clock.finish()
        await drain()
    }
    @Test("实际安装阶段取消准备计时，不能通过关窗中断")
    func installationIsNotTimedOut() async {
        let clock = UpdateWaiter()
        let driver = UpdateUserDriver(showsWindows: false, pause: { await clock.wait($0) })
        driver.begin(manual: true)
        driver.showDownloadDidStartExtractingUpdate()
        await drain()
        driver.showInstallingUpdate(withApplicationTerminated: false) {}
        clock.finish()
        await drain()
        #expect(driver.stage == .installing)
        #expect(driver.active)
        #expect(!driver.panel.model.canClose)
        driver.panel.model.close()
        #expect(driver.active)
        driver.showUpdateInstalledAndRelaunched(true) {}
    }
    @Test("框架开始失败也释放检查状态，可直接重试")
    func startFailure() {
        var attempts = 0
        let model = UpdateModel(
            enabled: true, scheduled: false, showsWindows: false,
            makeSession: { _ in
                attempts += 1
                return FakeUpdateSession(failure: NSError(domain: SUSparkleErrorDomain, code: 5))
            })
        model.check()
        #expect(attempts == 1)
        #expect(!model.checking && model.canCheck)
        #expect(model.panel.model.primary == "重试")
        #expect(model.panel.model.title == UpdateFailure.configuration.title)
        model.panel.model.performPrimary()
        #expect(attempts == 2)
        model.stop()
    }
    @Test("服务器和签名错误从嵌套错误中分类，不能一概提示网络异常")
    func errorClassification() {
        func wrapped(_ error: NSError) -> NSError {
            NSError(domain: SUSparkleErrorDomain, code: 1002, userInfo: [NSUnderlyingErrorKey: error])
        }
        for status in [403, 404, 429, 503] {
            let error = NSError(
                domain: SUSparkleErrorDomain, code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "Download failed (\(status))"])
            #expect(UpdateFailure(wrapped(error)) == .http(status))
        }
        #expect(UpdateFailure(wrapped(URLError(.notConnectedToInternet) as NSError)) == .offline)
        #expect(UpdateFailure(wrapped(URLError(.timedOut) as NSError)) == .timedOut(.checking))
        #expect(UpdateFailure(wrapped(NSError(domain: SUSparkleErrorDomain, code: 3001))) == .invalidSignature)
        #expect(UpdateFailure(wrapped(NSError(domain: SUSparkleErrorDomain, code: 1000))) == .invalidFeed)
    }
}

@MainActor
private final class UpdateWaiter {
    private var waits: [CheckedContinuation<Void, Never>?] = []
    var count: Int { waits.count }
    func wait(_ duration: Duration) async {
        await withCheckedContinuation { waits.append($0) }
    }
    func fire(_ index: Int) {
        guard waits.indices.contains(index) else { return }
        let continuation = waits[index]
        waits[index] = nil
        continuation?.resume()
    }
    func finish() { for index in waits.indices { fire(index) } }
}

@MainActor
private final class FakeUpdateSession: UpdateSession {
    let failure: Error?
    init(failure: Error? = nil) { self.failure = failure }
    func start() throws { if let failure { throw failure } }
}
