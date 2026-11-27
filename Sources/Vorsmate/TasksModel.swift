// [INPUT]: TasksHubClientProtocol、ProjectTasksProjection、VorsmatePlugin 生命周期与 NSWorkspace 打开回调。
// [OUTPUT]: 待办插件状态机；管理零开销启停、面板可见时轮询、Project 待办投影、完成切换、快速添加与 codex:// 打开。
// [POS]: AppModel 装配的可选工具模块；默认关闭，停用时立即取消全部轮询与在途请求。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Foundation
import VorsmateCore
import VorsmateSystem

@MainActor
final class TasksModel: ObservableObject, VorsmatePlugin {
    let id = PluginID.tasks

    @Published private(set) var active = false
    @Published private(set) var connectionState: TasksConnectionState = .disabled
    @Published private(set) var projection = ProjectTasksProjection()
    @Published private(set) var loading = false
    @Published private(set) var mutating = false
    @Published private(set) var actionError: String?
    @Published var selectedQuickAddListID = ""

    var summaryStatus: String {
        TasksSummaryFormatter.statusText(state: connectionState)
    }

    var summaryValue: String? {
        TasksSummaryFormatter.valueText(state: connectionState, incompleteCount: projection.totalIncompleteCount)
    }

    var overviewAccessibilityValue: String {
        TasksSummaryFormatter.overviewAccessibilityValue(
            state: connectionState,
            incompleteCount: projection.totalIncompleteCount
        )
    }

    var isPollingActive: Bool { pollTask != nil }

    private let client: any TasksHubClientProtocol
    private let openURL: @MainActor (URL) -> Bool
    private let pollInterval: Duration
    private var panelVisible = false
    private var lifecycleGeneration: UInt64 = 0
    private var fetchGeneration: UInt64 = 0
    private var fetchTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(
        preview: Bool = false,
        offlinePreview: Bool = false,
        client: (any TasksHubClientProtocol)? = nil,
        pollInterval: Duration = .seconds(15),
        openURL: (@MainActor (URL) -> Bool)? = nil
    ) {
        if let client {
            self.client = client
        } else if preview {
            self.client = PreviewTasksHubClient(offline: offlinePreview)
        } else {
            self.client = TasksHubClient()
        }
        self.pollInterval = pollInterval
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
    }

    func activate() {
        guard !active else { return }
        active = true
        lifecycleGeneration &+= 1
        actionError = nil
        connectionState = .connecting
        startFetch(showLoading: true)
        syncPolling()
    }

    func deactivate() {
        guard active || fetchTask != nil || mutationTask != nil || pollTask != nil else { return }
        active = false
        panelVisible = false
        lifecycleGeneration &+= 1
        fetchGeneration &+= 1
        fetchTask?.cancel()
        fetchTask = nil
        mutationTask?.cancel()
        mutationTask = nil
        pollTask?.cancel()
        pollTask = nil
        loading = false
        mutating = false
        actionError = nil
        projection = ProjectTasksProjection()
        selectedQuickAddListID = ""
        connectionState = .disabled
    }

    func refresh() {
        guard active else { return }
        actionError = nil
        startFetch(showLoading: connectionState != .connected)
    }

    func panelDidChangeVisibility(_ visible: Bool) {
        panelVisible = visible
        guard active else { return }
        if visible {
            startFetch(showLoading: connectionState != .connected)
        }
        syncPolling()
    }

    func completeItem(_ item: ReminderItem) {
        guard active, !mutating else { return }
        actionError = nil
        mutating = true
        let generation = lifecycleGeneration
        mutationTask?.cancel()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.setCompleted(itemID: item.id, completed: true)
                let tree = try await client.fetchTree(includeCompleted: false)
                guard !Task.isCancelled, self.active, self.lifecycleGeneration == generation else { return }
                self.apply(tree: tree)
                self.mutating = false
                self.mutationTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.active, self.lifecycleGeneration == generation else { return }
                self.mutating = false
                self.mutationTask = nil
                self.handleMutationFailure(error)
            }
        }
    }

    func addItem(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !mutating, !trimmed.isEmpty, let listID = resolvedQuickAddListID() else { return }
        actionError = nil
        mutating = true
        let generation = lifecycleGeneration
        mutationTask?.cancel()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.createItem(title: trimmed, listID: listID)
                let tree = try await client.fetchTree(includeCompleted: false)
                guard !Task.isCancelled, self.active, self.lifecycleGeneration == generation else { return }
                self.apply(tree: tree)
                self.mutating = false
                self.mutationTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.active, self.lifecycleGeneration == generation else { return }
                self.mutating = false
                self.mutationTask = nil
                self.handleMutationFailure(error)
            }
        }
    }

    @discardableResult
    func openCodexURL(_ item: ReminderItem) -> Bool {
        guard active, let url = item.codexURL else { return false }
        return openURL(url)
    }

    private func resolvedQuickAddListID() -> String? {
        if projection.projectLists.contains(where: { $0.id == selectedQuickAddListID }) {
            return selectedQuickAddListID
        }
        return projection.projectLists.first?.id
    }

    private func startFetch(showLoading: Bool) {
        guard active else { return }
        fetchGeneration &+= 1
        let generation = lifecycleGeneration
        let requestID = fetchGeneration
        if showLoading || connectionState != .connected {
            loading = true
            if connectionState == .offline {
                connectionState = .connecting
            }
        }
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tree = try await client.fetchTree(includeCompleted: false)
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == generation,
                    self.fetchGeneration == requestID
                else { return }
                self.apply(tree: tree)
                self.loading = false
                self.fetchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                    self.active,
                    self.lifecycleGeneration == generation,
                    self.fetchGeneration == requestID
                else { return }
                self.loading = false
                self.fetchTask = nil
                self.handleFetchFailure(error)
            }
        }
    }

    private func syncPolling() {
        pollTask?.cancel()
        pollTask = nil
        guard active, panelVisible else { return }
        let generation = lifecycleGeneration
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, self.active, self.panelVisible,
                    self.lifecycleGeneration == generation
                else { return }
                if !self.loading && !self.mutating {
                    self.startFetch(showLoading: false)
                }
            }
        }
    }

    private func apply(tree: ReminderTree) {
        let next = ProjectTasksProjection.project(from: tree)
        projection = next
        connectionState = .connected
        actionError = nil
        if !next.projectLists.contains(where: { $0.id == selectedQuickAddListID }) {
            selectedQuickAddListID = next.projectLists.first?.id ?? ""
        }
    }

    private func handleFetchFailure(_ error: Error) {
        if let hubError = error as? TasksHubError, hubError.isOfflineLike {
            projection = ProjectTasksProjection()
            selectedQuickAddListID = ""
            connectionState = .offline
            actionError = nil
        } else {
            if connectionState != .connected {
                connectionState = .offline
            }
            actionError = error.localizedDescription
        }
    }

    private func handleMutationFailure(_ error: Error) {
        if let hubError = error as? TasksHubError, hubError.isOfflineLike {
            projection = ProjectTasksProjection()
            selectedQuickAddListID = ""
            connectionState = .offline
            actionError = nil
        } else {
            actionError = error.localizedDescription
        }
    }
}

actor PreviewTasksHubClient: TasksHubClientProtocol {
    private let offline: Bool
    private var items: [ReminderItem]
    private var nextIndex = 100

    private let groups = [
        ReminderGroup(id: "grp-project", title: "Project"),
        ReminderGroup(id: "grp-daily", title: "日常"),
    ]

    private let lists = [
        ReminderList(id: "list-palboo", title: "Palboo", groupID: "grp-project"),
        ReminderList(id: "list-vorsmate", title: "Vorsmate", groupID: "grp-project"),
        ReminderList(id: "list-0xtotoro", title: "0xTotoro", groupID: "grp-project"),
        ReminderList(id: "list-daily", title: "提醒", groupID: "grp-daily"),
    ]

    private let sections = [
        ReminderSection(id: "sec-test", title: "测试分区", listID: "list-palboo")
    ]

    init(offline: Bool = false) {
        self.offline = offline
        self.items = [
            ReminderItem(
                id: "item-1",
                title: "验收开发版后决定是否恢复发布",
                url: "codex://threads/019d3e8f-1234-7000-8000-000000000001",
                completed: false,
                listID: "list-palboo",
                sectionID: "sec-test"
            ),
            ReminderItem(
                id: "item-2",
                title: "检查可选待办模块与本地 Hub 离线回退",
                url: "codex://threads/019d3e8f-1234-7000-8000-000000000002",
                completed: false,
                listID: "list-vorsmate"
            ),
            ReminderItem(
                id: "item-3",
                title: "核对 LaunchAgent 鉴权与 SSE 同步延迟",
                completed: false,
                listID: "list-0xtotoro"
            ),
            ReminderItem(
                id: "item-daily",
                title: "日常采购牛奶",
                completed: false,
                listID: "list-daily"
            ),
        ]
    }

    func fetchTree(includeCompleted: Bool) async throws -> ReminderTree {
        if offline { throw TasksHubError.unconfigured }
        let filtered = includeCompleted ? items : items.filter { !$0.completed }
        return ReminderTree(schemaVersion: 2, groups: groups, lists: lists, sections: sections, items: filtered)
    }

    func setCompleted(itemID: String, completed: Bool) async throws {
        if offline { throw TasksHubError.unconfigured }
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].completed = completed
    }

    func createItem(title: String, listID: String) async throws {
        if offline { throw TasksHubError.unconfigured }
        nextIndex += 1
        items.insert(
            ReminderItem(id: "preview-\(nextIndex)", title: title, completed: false, listID: listID),
            at: 0
        )
    }
}
