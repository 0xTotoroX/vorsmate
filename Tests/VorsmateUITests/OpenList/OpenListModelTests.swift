// [INPUT]: OpenListModel、延迟回执和可替换的网页与 Finder 启动。
// [OUTPUT]: 关闭面板不取消挂载，重复操作拦截，安全停止错误显示并回读。
// [POS]: 面板状态测试，不连接实际网盘与浏览器。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateSystem

@testable import Vorsmate

@Suite("网盘界面操作")
@MainActor
struct OpenListModelTests {
    @Test("停用期间已发起的开启仍可完成，且不会发起第二次")
    func activeOperationFinishesWithoutPanel() async {
        let client = TestOpenList()
        var opened = 0
        let model = OpenListModel(
            client: client, showURL: { _ in false },
            openMounts: {
                opened += 1
                return true
            }, openConfiguration: {})
        model.perform(.start)
        #expect(model.pending == nil)
        model.activate()
        model.perform(.start)
        model.perform(.start)
        model.panelDidChangeVisibility(false)
        model.deactivate()
        for _ in 0..<200 where model.pending != nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.pending == nil)
        #expect(await client.starts == 1)
        #expect(opened == 1 && model.status?.mounted == 4)
    }

    @Test("安全关闭被拒绝时保留已挂载状态与具体原因")
    func rejectedStopKeepsState() async {
        let client = TestOpenList()
        let model = OpenListModel(
            client: client, showURL: { _ in false }, openMounts: { true }, openConfiguration: {})
        model.activate()
        model.perform(.stop)
        for _ in 0..<200 where model.pending != nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.pending == nil)
        #expect(model.error == .operationRejected("仍有待上传修改"))
        #expect(model.status?.mounted == 4 && model.indicator == .error)
    }

    private actor TestOpenList: OpenListClientProtocol {
        private(set) var starts = 0
        func status() -> OpenListStatus { OpenListStatus(mounted: 4, total: 4, connectionLoaded: true) }
        func start() async {
            starts += 1
            try? await Task.sleep(for: .milliseconds(30))
        }
        func stop() throws { throw OpenListError.operationRejected("仍有待上传修改") }
        func webInterface() throws -> URL { throw OpenListError.invalidResponse }
    }
}
