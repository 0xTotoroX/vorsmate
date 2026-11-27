// [INPUT]: TasksModel、PluginHost 与内存 Mock TasksHubClientProtocol。
// [OUTPUT]: 默认关闭与 PluginHost 启停零开销生命周期、离线回退、速记保存回执和勾选回归。
// [POS]: UI 层待办状态机测试，不连接真实本地 Hub 或真实 Apple Reminders。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateSystem

@testable import Vorsmate

@Suite("待办插件状态机与生命周期")
@MainActor
struct TasksModelTests {
    @Test("默认关闭不发起请求，启用后按面板显隐启停轮询，停用立即取消并忽略迟到响应")
    func pluginHostLifecycleAndZeroOverhead() async throws {
        let mock = MockTasksHubClient()
        let model = TasksModel(client: mock, pollInterval: .milliseconds(40))
        var disabled: Set<PluginID> = Preferences().disabledAtRuntime
        let host = PluginHost(plugins: [model], disabled: disabled) { disabled = $0 }

        host.start()
        #expect(!model.active)
        #expect(model.connectionState == .disabled)
        #expect(!model.isPollingActive)
        #expect(await mock.fetchCount == 0)

        try host.setEnabled(true, for: .tasks)
        await waitUntil { model.connectionState == .connected }
        #expect(model.active)
        #expect(model.projection.totalIncompleteCount == 1)
        #expect(model.summaryValue == "1 项未完成")
        #expect(!model.isPollingActive)

        host.panelDidChangeVisibility(true)
        #expect(model.isPollingActive)
        let fetchesAfterVisible = await mock.fetchCount
        try await Task.sleep(for: .milliseconds(120))
        #expect(await mock.fetchCount > fetchesAfterVisible)

        host.panelDidChangeVisibility(false)
        #expect(!model.isPollingActive)

        await mock.setDelay(.milliseconds(120))
        host.refresh()
        try host.setEnabled(false, for: .tasks)
        #expect(!model.active)
        #expect(model.connectionState == .disabled)
        #expect(!model.isPollingActive)
        #expect(model.projection.buckets.isEmpty)

        try await Task.sleep(for: .milliseconds(180))
        #expect(!model.active)
        #expect(model.connectionState == .disabled)
        #expect(model.projection.buckets.isEmpty)
        host.stop()
    }

    @Test("Hub 缺失或不可达时干净进入未连接状态，不抛出界面错误")
    func offlineFallbackWithoutErrors() async {
        let mock = MockTasksHubClient(failure: .unconfigured)
        let model = TasksModel(client: mock)
        model.activate()

        await waitUntil { model.connectionState == .offline }
        #expect(model.summaryStatus == "未连接")
        #expect(model.summaryValue == nil)
        #expect(model.actionError == nil)
        #expect(model.projection.buckets.isEmpty)

        model.deactivate()
    }

    @Test("待办服务返回 500 时显示读取失败，重试成功后恢复实际列表")
    func serverErrorCanRecover() async {
        let mock = MockTasksHubClient(failure: .httpError(500))
        let model = TasksModel(client: mock)
        model.activate()
        await waitUntil { !model.loading }
        #expect(model.connectionState == .readFailed)
        #expect(model.actionError?.contains("500") == true)
        await mock.setFailure(nil)
        model.refresh()
        await waitUntil { !model.loading }
        #expect(model.connectionState == .connected)
        #expect(model.projection.totalIncompleteCount == 1)
        #expect(model.actionError == nil)
        await mock.setFailure(.unauthorized)
        model.refresh()
        await waitUntil { model.connectionState == .readFailed }
        #expect(model.projection.projectLists.isEmpty)
        #expect(model.actionError == TasksHubError.unauthorized.localizedDescription)
        model.deactivate()
    }

    @Test("速记只在写入成功后确认，一键完成使用原事项")
    func quickAddAndComplete() async throws {
        let mock = MockTasksHubClient()
        let model = TasksModel(client: mock)
        model.activate()
        await waitUntil { model.connectionState == .connected }

        let initialItem = try #require(model.projection.buckets.first?.items.first?.item)
        var saved = 0
        await mock.setFailure(.httpError(500))
        model.addItem(title: "编写单元测试", listID: "list-vorsmate") { saved += 1 }
        await waitUntil { !model.mutating }
        #expect(saved == 0)
        await mock.setFailure(nil)
        model.addItem(title: "  编写单元测试  ", listID: "list-vorsmate") { saved += 1 }
        await waitUntil { model.projection.totalIncompleteCount == 2 }
        #expect(saved == 1)
        let created = await mock.createdItems
        #expect(created.count == 1)
        #expect(created.first?.title == "编写单元测试")
        #expect(created.first?.listID == "list-vorsmate")

        model.renameItem(initialItem, to: "新标题") { saved += 1 }
        await waitUntil { !model.mutating }
        #expect(saved == 2)
        let renamed = try #require(model.projection.buckets.first?.items.first?.item)
        #expect(renamed.title == "新标题")
        #expect(renamed.url == initialItem.url)
        model.renameItem(initialItem, to: "旧视图改名") { saved += 1 }
        await waitUntil { !model.mutating }
        #expect(saved == 2)

        model.completeItem(initialItem)
        await waitUntil { model.projection.totalIncompleteCount == 1 }
        #expect(await mock.completedIDs == [initialItem.id])
        #expect(model.projection.buckets.map(\.list.title) == ["Vorsmate"])

        model.deactivate()
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor MockTasksHubClient: TasksHubClientProtocol {
    struct CreatedItem: Equatable {
        let title: String
        let listID: String
    }
    var fetchCount = 0
    var createdItems: [CreatedItem] = []
    var completedIDs: [String] = []
    private var delay: Duration = .zero
    private var failure: TasksHubError?

    private let groups = [
        ReminderGroup(id: "grp-project", title: "Project")
    ]
    private let lists = [
        ReminderList(id: "list-palboo", title: "Palboo", groupID: "grp-project"),
        ReminderList(id: "list-vorsmate", title: "Vorsmate", groupID: "grp-project"),
    ]
    private let sections = [
        ReminderSection(id: "sec-test", title: "测试分区", listID: "list-palboo")
    ]
    private var items = [
        ReminderItem(
            id: "item-1",
            title: "验收开发版",
            url: "codex://threads/019d3e8f",
            completed: false,
            listID: "list-palboo",
            sectionID: "sec-test"
        )
    ]

    init(failure: TasksHubError? = nil) {
        self.failure = failure
    }

    func setDelay(_ delay: Duration) {
        self.delay = delay
    }

    func setFailure(_ failure: TasksHubError?) {
        self.failure = failure
    }

    func fetchTree(includeCompleted: Bool) async throws -> ReminderTree {
        fetchCount += 1
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let failure { throw failure }
        let visible = includeCompleted ? items : items.filter { !$0.completed }
        return ReminderTree(schemaVersion: 2, groups: groups, lists: lists, sections: sections, items: visible)
    }

    func setCompleted(itemID: String, completed: Bool) async throws {
        if let failure { throw failure }
        completedIDs.append(itemID)
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].completed = completed
        }
    }

    func renameItem(itemID: String, title: String, expectedTitle: String) async throws {
        if let failure { throw failure }
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw TasksHubError.httpError(404) }
        guard items[index].title == expectedTitle else { throw TasksHubError.httpError(409) }
        items[index].title = title
    }

    func createItem(title: String, listID: String) async throws {
        if let failure { throw failure }
        createdItems.append(CreatedItem(title: title, listID: listID))
        items.append(ReminderItem(id: "new-\(createdItems.count)", title: title, completed: false, listID: listID))
    }
}
