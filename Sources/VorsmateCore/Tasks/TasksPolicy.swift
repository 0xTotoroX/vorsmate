// [INPUT]: 已解码的待办树和连接状态。
// [OUTPUT]: Project 分组投影与面板摘要文案。
// [POS]: 不用连接器就能验证的待办展示规则。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct ProjectReminderEntry: Equatable, Sendable, Identifiable {
    public let item: ReminderItem
    public let sectionTitle: String?
    public var id: String { item.id }

    public init(item: ReminderItem, sectionTitle: String? = nil) {
        self.item = item
        self.sectionTitle = sectionTitle
    }
}

public struct ProjectReminderBucket: Equatable, Sendable, Identifiable {
    public let list: ReminderList
    public let items: [ProjectReminderEntry]
    public var id: String { list.id }

    public init(list: ReminderList, items: [ProjectReminderEntry]) {
        self.list = list
        self.items = items
    }
}

public struct ProjectTasksProjection: Equatable, Sendable {
    public let projectLists: [ReminderList]
    public let buckets: [ProjectReminderBucket]
    public let totalIncompleteCount: Int

    public init(
        projectLists: [ReminderList] = [],
        buckets: [ProjectReminderBucket] = [],
        totalIncompleteCount: Int = 0
    ) {
        self.projectLists = projectLists
        self.buckets = buckets
        self.totalIncompleteCount = totalIncompleteCount
    }

    public static func project(from tree: ReminderTree, groupName: String = "Project") -> ProjectTasksProjection {
        let normalizedTarget = groupName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchingGroupIDs = Set(
            tree.groups.filter {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTarget
            }.map(\.id)
        )
        let projectLists = tree.lists.filter { list in
            guard let groupID = list.groupID else { return false }
            return matchingGroupIDs.contains(groupID)
        }
        let sectionTitles = Dictionary(uniqueKeysWithValues: tree.sections.map { ($0.id, $0.title) })
        let itemsByList = Dictionary(grouping: tree.items.filter { !$0.completed }) { $0.listID ?? "" }

        var buckets: [ProjectReminderBucket] = []
        var totalCount = 0
        for list in projectLists {
            guard let rawItems = itemsByList[list.id], !rawItems.isEmpty else { continue }
            let entries = rawItems.map { item in
                let rawSection = item.sectionID.flatMap { sectionTitles[$0] }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let sectionTitle = (rawSection?.isEmpty == false) ? rawSection : nil
                return ProjectReminderEntry(item: item, sectionTitle: sectionTitle)
            }
            buckets.append(ProjectReminderBucket(list: list, items: entries))
            totalCount += entries.count
        }
        return ProjectTasksProjection(
            projectLists: projectLists,
            buckets: buckets,
            totalIncompleteCount: totalCount
        )
    }
}

public enum TasksConnectionState: Equatable, Sendable {
    case disabled
    case connecting
    case connected
    case offline
    case readFailed
}

public enum TasksSummaryFormatter {
    public static func statusText(state: TasksConnectionState) -> String {
        switch state {
        case .disabled: "未启用"
        case .connecting: "连接中"
        case .connected: "Project"
        case .offline: "未连接"
        case .readFailed: "读取失败"
        }
    }

    public static func valueText(state: TasksConnectionState, incompleteCount: Int) -> String? {
        switch state {
        case .connected: "\(max(0, incompleteCount)) 项未完成"
        case .disabled, .connecting, .offline, .readFailed: nil
        }
    }

    public static func overviewAccessibilityValue(state: TasksConnectionState, incompleteCount: Int) -> String {
        switch state {
        case .disabled: "未启用"
        case .connecting: "连接中"
        case .connected: "待办 · \(max(0, incompleteCount)) 项未完成"
        case .offline: "未连接"
        case .readFailed: "读取失败"
        }
    }
}
