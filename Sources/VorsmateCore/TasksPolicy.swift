// [INPUT]: Foundation、提醒事项连接器的新旧配对路径与 Reminders tree JSON。
// [OUTPUT]: Hub 连接配置解析、ReminderTree 模型、Project 分组投影与摘要格式化。
// [POS]: VorsmateCore 纯数据与规则层；不发起网络请求或依赖 AppKit。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct HubRuntimeInfo: Codable, Equatable, Sendable {
    public var url: String?
    public var port: Int?
    public var token: String
    public var pid: Int?

    public init(url: String? = nil, port: Int? = nil, token: String, pid: Int? = nil) {
        self.url = url
        self.port = port
        self.token = token
        self.pid = pid
    }

    public static func defaultRuntimeURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let shared = homeDirectory.appending(path: "Library/Application Support/RemindersConnector/runtime.json")
        let legacy = homeDirectory.appending(path: ".local/share/0xTotoro/runtime.json")
        if !FileManager.default.fileExists(atPath: shared.path), FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return shared
    }

    public static func load(from url: URL) throws -> HubRuntimeInfo? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(HubRuntimeInfo.self, from: data)
    }

    public var resolvedBaseURL: URL? {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return nil }

        if let rawURL = url?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty,
            let parsed = URL(string: rawURL),
            Self.isAllowedLoopbackURL(parsed)
        {
            return parsed
        }

        if let port, (1...65535).contains(port) {
            return URL(string: "http://127.0.0.1:\(port)")
        }
        return nil
    }

    public static func isAllowedLoopbackURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http",
            let host = url.host?.lowercased()
        else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

public struct ReminderGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let title = try container.decodeIfPresent(String.self, forKey: .title) {
            self.title = title
        } else {
            self.title = try container.decode(String.self, forKey: .name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
    }
}

public struct ReminderList: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var groupID: String?
    public var color: String?

    public init(id: String, title: String, groupID: String? = nil, color: String? = nil) {
        self.id = id
        self.title = title
        self.groupID = groupID
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, name, color
        case parentGroupID = "parent_group_id"
        case groupID = "group_id"
        case groupIDCamel = "groupId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let title = try container.decodeIfPresent(String.self, forKey: .title) {
            self.title = title
        } else {
            self.title = try container.decode(String.self, forKey: .name)
        }
        groupID =
            try container.decodeIfPresent(String.self, forKey: .parentGroupID)
            ?? container.decodeIfPresent(String.self, forKey: .groupID)
            ?? container.decodeIfPresent(String.self, forKey: .groupIDCamel)
        color = try container.decodeIfPresent(String.self, forKey: .color)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(groupID, forKey: .groupID)
        try container.encodeIfPresent(color, forKey: .color)
    }
}

public struct ReminderSection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var listID: String?

    public init(id: String, title: String, listID: String? = nil) {
        self.id = id
        self.title = title
        self.listID = listID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, name
        case listID = "list_id"
        case listIDCamel = "listId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let title = try container.decodeIfPresent(String.self, forKey: .title) {
            self.title = title
        } else {
            self.title = try container.decode(String.self, forKey: .name)
        }
        listID =
            try container.decodeIfPresent(String.self, forKey: .listID)
            ?? container.decodeIfPresent(String.self, forKey: .listIDCamel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(listID, forKey: .listID)
    }
}

public struct ReminderItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var notes: String?
    public var url: String?
    public var completed: Bool
    public var priority: Int?
    public var flagged: Bool?
    public var due: String?
    public var allDay: Bool?
    public var timeZone: String?
    public var listID: String?
    public var sectionID: String?

    public init(
        id: String,
        title: String,
        notes: String? = nil,
        url: String? = nil,
        completed: Bool = false,
        priority: Int? = nil,
        flagged: Bool? = nil,
        due: String? = nil,
        allDay: Bool? = nil,
        timeZone: String? = nil,
        listID: String? = nil,
        sectionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.url = url
        self.completed = completed
        self.priority = priority
        self.flagged = flagged
        self.due = due
        self.allDay = allDay
        self.timeZone = timeZone
        self.listID = listID
        self.sectionID = sectionID
    }

    /// Keep authored titles intact in storage while omitting chat links from the checklist.
    public var displayTitle: String {
        let address =
            #"(?i)(?:codex://|https?://(?:chatgpt\.com|chat\.openai\.com)/codex(?:/|(?=[?#\s)>]|$)))[^\s<>()\[\]，。；！？、」』】）]*"#
        guard title.range(of: address, options: .regularExpression) != nil else { return title }
        let markdown = #"\[([^\]]*)\]\(\s*<?"# + address + #">?\s*\)"#
        let text =
            title
            .replacingOccurrences(of: markdown, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "<?" + address + ">?", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+(?=[，。；！？、])"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "无标题待办" : text
    }

    public var codexURL: URL? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let parsed = URL(string: raw),
            parsed.scheme?.lowercased() == "codex"
        else { return nil }
        return parsed
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, url, completed, priority, flagged, due
        case allDay = "all_day"
        case allDayCamel = "allDay"
        case timeZone = "time_zone"
        case timeZoneCamel = "timeZone"
        case listID = "list_id"
        case listIDCamel = "listId"
        case sectionID = "section_id"
        case sectionIDCamel = "sectionId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        flagged = try container.decodeIfPresent(Bool.self, forKey: .flagged)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        allDay =
            try container.decodeIfPresent(Bool.self, forKey: .allDay)
            ?? container.decodeIfPresent(Bool.self, forKey: .allDayCamel)
        timeZone =
            try container.decodeIfPresent(String.self, forKey: .timeZone)
            ?? container.decodeIfPresent(String.self, forKey: .timeZoneCamel)
        listID =
            try container.decodeIfPresent(String.self, forKey: .listID)
            ?? container.decodeIfPresent(String.self, forKey: .listIDCamel)
        sectionID =
            try container.decodeIfPresent(String.self, forKey: .sectionID)
            ?? container.decodeIfPresent(String.self, forKey: .sectionIDCamel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(completed, forKey: .completed)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(flagged, forKey: .flagged)
        try container.encodeIfPresent(due, forKey: .due)
        try container.encodeIfPresent(allDay, forKey: .allDay)
        try container.encodeIfPresent(timeZone, forKey: .timeZone)
        try container.encodeIfPresent(listID, forKey: .listID)
        try container.encodeIfPresent(sectionID, forKey: .sectionID)
    }
}

public struct ReminderTree: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var groups: [ReminderGroup]
    public var lists: [ReminderList]
    public var sections: [ReminderSection]
    public var items: [ReminderItem]

    public init(
        schemaVersion: Int = 2,
        groups: [ReminderGroup] = [],
        lists: [ReminderList] = [],
        sections: [ReminderSection] = [],
        items: [ReminderItem] = []
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.lists = lists
        self.sections = sections
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case schemaVersionCamel = "schemaVersion"
        case accounts, groups, lists, sections, items
    }

    private struct AccountPayload: Decodable {
        let groups: [ReminderGroup]?
        let lists: [AccountListPayload]?
    }

    private struct AccountListPayload: Decodable {
        let id: String
        let title: String
        let parentGroupID: String?
        let color: String?
        let sections: [ReminderSection]?
        let items: [ReminderItem]?

        private enum CodingKeys: String, CodingKey {
            case id, title, name, color, sections, items
            case parentGroupID = "parent_group_id"
            case groupID = "group_id"
            case groupIDCamel = "groupId"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            if let title = try container.decodeIfPresent(String.self, forKey: .title) {
                self.title = title
            } else {
                self.title = try container.decode(String.self, forKey: .name)
            }
            parentGroupID =
                try container.decodeIfPresent(String.self, forKey: .parentGroupID)
                ?? container.decodeIfPresent(String.self, forKey: .groupID)
                ?? container.decodeIfPresent(String.self, forKey: .groupIDCamel)
            color = try container.decodeIfPresent(String.self, forKey: .color)
            sections = try container.decodeIfPresent([ReminderSection].self, forKey: .sections)
            items = try container.decodeIfPresent([ReminderItem].self, forKey: .items)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .schemaVersionCamel)
            ?? 2

        var decodedGroups = try container.decodeIfPresent([ReminderGroup].self, forKey: .groups) ?? []
        var decodedLists = try container.decodeIfPresent([ReminderList].self, forKey: .lists) ?? []
        var decodedSections = try container.decodeIfPresent([ReminderSection].self, forKey: .sections) ?? []
        var decodedItems = try container.decodeIfPresent([ReminderItem].self, forKey: .items) ?? []

        if let accounts = try container.decodeIfPresent([AccountPayload].self, forKey: .accounts) {
            for account in accounts {
                if let accountGroups = account.groups {
                    decodedGroups.append(contentsOf: accountGroups)
                }
                for list in account.lists ?? [] {
                    decodedLists.append(
                        ReminderList(id: list.id, title: list.title, groupID: list.parentGroupID, color: list.color)
                    )
                    for var section in list.sections ?? [] {
                        if section.listID == nil { section.listID = list.id }
                        decodedSections.append(section)
                    }
                    for var item in list.items ?? [] {
                        if item.listID == nil { item.listID = list.id }
                        decodedItems.append(item)
                    }
                }
            }
        }

        groups = decodedGroups
        lists = decodedLists
        sections = decodedSections
        items = decodedItems
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(groups, forKey: .groups)
        try container.encode(lists, forKey: .lists)
        try container.encode(sections, forKey: .sections)
        try container.encode(items, forKey: .items)
    }
}

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
