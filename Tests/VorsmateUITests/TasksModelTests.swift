// [INPUT]: TasksModel、PluginHost 与内存 Mock TasksHubClientProtocol。
// [OUTPUT]: 默认关闭与 PluginHost 启停零开销生命周期、离线回退、快速添加、完成切换与 codex:// 打开回归。
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

    @Test("快速添加、一键完成与打开 codex:// URL 正常工作")
    func quickAddCompleteAndOpenCodexURL() async throws {
        let mock = MockTasksHubClient()
        var openedURLs: [URL] = []
        let model = TasksModel(
            client: mock,
            openURL: { url in
                openedURLs.append(url)
                return true
            }
        )
        model.activate()
        await waitUntil { model.connectionState == .connected }

        let initialItem = try #require(model.projection.buckets.first?.items.first?.item)
        #expect(model.openCodexURL(initialItem))
        #expect(openedURLs.map(\.absoluteString) == ["codex://threads/019d3e8f"])

        model.selectedQuickAddListID = "list-vorsmate"
        model.addItem(title: "  编写单元测试  ")
        await waitUntil { model.projection.totalIncompleteCount == 2 }
        let created = await mock.createdItems
        #expect(created.count == 1)
        #expect(created.first?.title == "编写单元测试")
        #expect(created.first?.listID == "list-vorsmate")

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
    private let failure: TasksHubError?

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

    func createItem(title: String, listID: String) async throws {
        if let failure { throw failure }
        createdItems.append(CreatedItem(title: title, listID: listID))
        items.append(ReminderItem(id: "new-\(createdItems.count)", title: title, completed: false, listID: listID))
    }
}
