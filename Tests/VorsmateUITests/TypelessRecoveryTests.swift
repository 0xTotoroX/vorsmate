// [INPUT]: 仅内存诊断和 App 操作替身。
// [OUTPUT]: 验证故障提示、保存和确认顺序、退出超时与取消。
import Testing
import VorsmateSystem

@testable import Vorsmate

@Suite("Typeless 诊断与恢复")
@MainActor
struct TypelessRecoveryTests {
    @Test("键盘故障和遥控器接管失败给出各自的排查入口")
    func routes() {
        let keyboard = TypelessRecoveryModel.preview(remoteFault: false, timesOut: false)
        keyboard.refresh()
        #expect(keyboard.snapshot?.listener == .disabled)
        #expect(keyboard.snapshot?.modifiers == ["左 Control", "Fn"])
        #expect(keyboard.snapshot?.guidance.contains("重新打开 Typeless") == true)

        let remote = TypelessRecoveryModel.preview(remoteFault: true, timesOut: false)
        remote.refresh()
        #expect(remote.snapshot?.listener == .enabled)
        #expect(remote.snapshot?.remoteConnection == .connected)
        #expect(remote.snapshot?.remoteTakeover == .inactive)
        #expect(remote.snapshot?.guidance.contains("尚未接管") == true)
    }

    @Test("先保存，明确确认后正常退出，确认重复提交只执行一次")
    func confirmedRecovery() async {
        let operations = Operations()
        let model = operations.model()
        await model.confirm()
        #expect(operations.events.isEmpty)
        model.prepare()
        model.prepare()
        #expect(model.phase == .confirming)
        #expect(operations.events == ["save"])
        await model.confirm()
        await model.confirm()
        #expect(operations.events == ["save", "target", "terminate", "reopen"])
        guard case .finished = model.phase else {
            Issue.record("应该提示重新打开成功")
            return
        }
    }

    @Test("取消、保存失败、退出被拒绝和退出超时都不会重新启动")
    func failures() async {
        let canceled = Operations()
        let cancelModel = canceled.model()
        cancelModel.prepare()
        cancelModel.cancelConfirmation()
        await cancelModel.confirm()
        #expect(canceled.events == ["save"])

        let failedSave = Operations()
        failedSave.saveFails = true
        let failingModel = failedSave.model()
        failingModel.prepare()
        await failingModel.confirm()
        #expect(failedSave.events == ["save"])
        guard case .failed = failingModel.phase else {
            Issue.record("应显示保存失败")
            return
        }

        let rejected = Operations()
        rejected.acceptsExit = false
        let rejectedModel = rejected.model()
        rejectedModel.prepare()
        await rejectedModel.confirm()
        #expect(rejected.events == ["save", "target", "terminate"])
        guard case .failed(let rejection) = rejectedModel.phase else {
            Issue.record("应显示退出被拒绝")
            return
        }
        #expect(rejection.contains("未接受退出请求"))

        let timeout = Operations()
        timeout.exited = false
        let timeoutModel = timeout.model()
        timeoutModel.prepare()
        await timeoutModel.confirm()
        #expect(timeout.events == ["save", "target", "terminate"])
        guard case .failed(let message) = timeoutModel.phase else {
            Issue.record("应显示超时")
            return
        }
        #expect(message.contains("退出超时"))
    }

    @MainActor
    private final class Operations {
        private enum Failure: Error { case save }
        var events: [String] = []
        var saveFails = false
        var acceptsExit = true
        var exited = true

        func model() -> TypelessRecoveryModel {
            TypelessRecoveryModel(
                read: {
                    TypelessDiagnosis(
                        running: true, listener: .disabled, modifiers: [], remoteConnection: .connected,
                        remoteTakeover: .active)
                },
                save: { _ in
                    self.events.append("save")
                    if self.saveFails { throw Failure.save }
                },
                target: {
                    self.events.append("target")
                    return TypelessRestartTarget(
                        requestExit: {
                            self.events.append("terminate")
                            return self.acceptsExit
                        },
                        hasExited: { self.exited },
                        open: { self.events.append("reopen") })
                },
                exitTimeout: .milliseconds(10))
        }
    }
}
