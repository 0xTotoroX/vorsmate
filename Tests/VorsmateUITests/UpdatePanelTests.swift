// [INPUT]: 更新交互模型及框架回调替身，不请求网络、不执行安装。
// [OUTPUT]: 一次性动作、关闭确认和进度边界回归。
// [POS]: 更新自定义交互层的生命周期测试，安装另作隔离验收。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Testing

@testable import Vorsmate

@Suite("更新交互")
@MainActor
struct UpdatePanelTests {
    @Test("安装、稍后和关闭只消费一次回调", arguments: ["primary", "secondary", "close"])
    func once(action: String) {
        let model = UpdatePanelModel()
        var install = 0
        var dismiss = 0
        model.present(
            "可以更新了", detail: "", primary: "重启更新", action: { install += 1 }, secondary: "稍后", cancel: { dismiss += 1 })
        if action == "primary" { model.performPrimary() }
        if action == "secondary" { model.performSecondary() }
        if action == "close" { model.close() }
        model.performPrimary()
        model.close()
        #expect(install + dismiss == 1)
        #expect(install == (action == "primary" ? 1 : 0))
    }
    @Test("回调产生新状态后不会清掉新按钮")
    func nextState() {
        let model = UpdatePanelModel()
        var completed = false
        model.present(
            "更新", detail: "", primary: "继续",
            action: {
                model.present("完成", detail: "", primary: "好", action: { completed = true })
            })
        model.performPrimary()
        #expect(model.primary == "好")
        model.close()
        #expect(completed)
    }
    @Test("安装关键阶段不能通过关窗中断")
    func nonCancellable() {
        let model = UpdatePanelModel()
        model.present("安装中", detail: "", busy: true)
        #expect(!model.canClose)
        model.close()
        #expect(model.busy)
    }
}
