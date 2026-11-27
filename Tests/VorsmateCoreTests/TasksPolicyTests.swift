// [INPUT]: HubRuntimeInfo、ReminderTree JSON、ProjectTasksProjection 与 Mock TasksHubTransport。
// [OUTPUT]: runtime.json 解析/离线回退、Reminders tree 投影、codex:// 校验与 Hub HTTP 客户端回归测试。
// [POS]: Core/System 待办逻辑测试，不访问真实本地文件或真实 Apple Reminders。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateSystem

@Suite("待办 Hub 解析与客户端")
struct TasksPolicyTests {
    @Test("清单只显示标题正文，原始链接与普通网站完整保留")
    func checklistTitle() {
        let title = "按[设计稿](codex://threads/test)核对"
        let item = ReminderItem(id: "1", title: title)
        #expect(item.displayTitle == "按设计稿核对")
        #expect(item.title == title)
        #expect(ReminderItem(id: "2", title: "<https://chatgpt.com/codex/tasks/test>").displayTitle == "无标题待办")
        #expect(
            ReminderItem(id: "3", title: "Codex CLI 与 https://example.com").displayTitle
                == "Codex CLI 与 https://example.com")
    }

    @Test("新旧客户端共用配对，并优先发现独立连接器")
    func sharedConnectorDiscovery() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let shared = home.appending(path: "Library/Application Support/RemindersConnector/runtime.json")
        let legacy = home.appending(path: ".local/share/0xTotoro/runtime.json")
        #expect(HubRuntimeInfo.defaultRuntimeURL(homeDirectory: home).path == shared.path)
        try fm.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy)
        #expect(HubRuntimeInfo.defaultRuntimeURL(homeDirectory: home).path == legacy.path)
        try fm.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: shared, withDestinationURL: legacy)
        #expect(HubRuntimeInfo.defaultRuntimeURL(homeDirectory: home).path == shared.path)
    }

    @Test("runtime.json 缺失返回 nil，合法回环地址与端口回退正确解析并拒绝非回环域名")
    func runtimeInfoParsingAndValidation() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missingURL = dir.appending(path: "missing-runtime.json")
        #expect(try HubRuntimeInfo.load(from: missingURL) == nil)

        let validURL = dir.appending(path: "runtime.json")
        try Data(#"{"url":"http://127.0.0.1:41937","port":41937,"token":"abc123","pid":42}"#.utf8).write(to: validURL)
        let loaded = try #require(try HubRuntimeInfo.load(from: validURL))
        #expect(loaded.token == "abc123")
        #expect(loaded.resolvedBaseURL?.absoluteString == "http://127.0.0.1:41937")

        let portFallback = HubRuntimeInfo(url: nil, port: 41937, token: "tok")
        #expect(portFallback.resolvedBaseURL?.absoluteString == "http://127.0.0.1:41937")

        let remoteHost = HubRuntimeInfo(url: "https://example.com:41937", port: nil, token: "tok")
        #expect(remoteHost.resolvedBaseURL == nil)

        let emptyToken = HubRuntimeInfo(url: "http://127.0.0.1:41937", port: 41937, token: "   ")
        #expect(emptyToken.resolvedBaseURL == nil)
    }

    @Test("ReminderTree JSON 解析与 Project 分组投影保留分区标签和 codex:// 链接")
    func treeDecodingAndProjectProjection() throws {
        let json = """
            {
              "schema_version": 2,
              "groups": [
                {"id": "g-project", "title": "Project"},
                {"id": "g-daily", "title": "日常"}
              ],
              "lists": [
                {"id": "l-palboo", "title": "Palboo", "group_id": "g-project"},
                {"id": "l-vorsmate", "title": "Vorsmate", "group_id": "g-project"},
                {"id": "l-empty", "title": "0xTotoro", "group_id": "g-project"},
                {"id": "l-daily", "title": "提醒", "group_id": "g-daily"}
              ],
              "sections": [
                {"id": "s-test", "title": "测试分区", "list_id": "l-palboo"}
              ],
              "items": [
                {
                  "id": "i-1",
                  "title": "验收开发版后决定是否恢复发布",
                  "notes": "检查日志",
                  "url": "codex://threads/019d3e8f",
                  "completed": false,
                  "priority": 1,
                  "flagged": false,
                  "due": "2026-11-28T10:00:00Z",
                  "all_day": false,
                  "time_zone": "Asia/Shanghai",
                  "list_id": "l-palboo",
                  "section_id": "s-test"
                },
                {
                  "id": "i-done",
                  "title": "已完成项不应出现",
                  "completed": true,
                  "list_id": "l-palboo"
                },
                {
                  "id": "i-2",
                  "title": "新增可选待办模块",
                  "url": "https://example.com",
                  "completed": false,
                  "list_id": "l-vorsmate"
                },
                {
                  "id": "i-daily",
                  "title": "日常采购",
                  "completed": false,
                  "list_id": "l-daily"
                }
              ]
            }
            """
        let tree = try JSONDecoder().decode(ReminderTree.self, from: Data(json.utf8))
        #expect(tree.schemaVersion == 2)
        let projection = ProjectTasksProjection.project(from: tree)

        #expect(projection.projectLists.map(\.title) == ["Palboo", "Vorsmate", "0xTotoro"])
        #expect(projection.totalIncompleteCount == 2)
        #expect(projection.buckets.map(\.list.title) == ["Palboo", "Vorsmate"])

        let palbooEntry = try #require(projection.buckets.first?.items.first)
        #expect(palbooEntry.sectionTitle == "测试分区")
        #expect(palbooEntry.item.codexURL?.absoluteString == "codex://threads/019d3e8f")

        let vorsmateEntry = try #require(projection.buckets.last?.items.first)
        #expect(vorsmateEntry.sectionTitle == nil)
        #expect(vorsmateEntry.item.codexURL == nil)
    }

    @Test("真实 0xTotoro Hub accounts 嵌套 tree JSON 正确解析并投影 Project 分组")
    func nestedAccountsTreeDecodingAndProjection() throws {
        let json = """
            {
              "schema_version": 2,
              "accounts": [
                {
                  "name": "iCloud",
                  "groups": [
                    {"id": "g-project", "name": "Project", "parent_group_id": null},
                    {"id": "g-daily", "name": "日常", "parent_group_id": null}
                  ],
                  "lists": [
                    {
                      "id": "l-palboo",
                      "name": "Palboo",
                      "parent_group_id": "g-project",
                      "sections": [{"id": "s-test", "name": "测试分区"}],
                      "items": [
                        {
                          "id": "i-1",
                          "title": "验收开发版后决定是否恢复发布",
                          "notes": "检查日志",
                          "url": "codex://threads/01a20c1d",
                          "completed": false,
                          "priority": 0,
                          "flagged": false,
                          "due": null,
                          "all_day": false,
                          "time_zone": null,
                          "section_id": "s-test"
                        }
                      ]
                    },
                    {
                      "id": "l-daily",
                      "name": "提醒",
                      "parent_group_id": "g-daily",
                      "sections": [],
                      "items": [
                        {"id": "i-d", "title": "壁纸", "completed": false, "section_id": null}
                      ]
                    }
                  ]
                }
              ]
            }
            """
        let tree = try JSONDecoder().decode(ReminderTree.self, from: Data(json.utf8))
        let projection = ProjectTasksProjection.project(from: tree)
        #expect(projection.projectLists.map(\.title) == ["Palboo"])
        #expect(projection.totalIncompleteCount == 1)
        let entry = try #require(projection.buckets.first?.items.first)
        #expect(entry.sectionTitle == "测试分区")
        #expect(entry.item.codexURL?.absoluteString == "codex://threads/01a20c1d")
    }

    @Test("TasksHubClient 在 runtime.json 缺失、断连、401 时安全返回离线错误，成功时带 Bearer Token 读写")
    func clientRequestsAndOfflineFallback() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtimeURL = dir.appending(path: "runtime.json")
        let transport = MockTasksHubTransport()
        let client = TasksHubClient(runtimeFileURL: runtimeURL, transport: transport)

        await #expect(throws: TasksHubError.unconfigured) {
            _ = try await client.fetchTree(includeCompleted: false)
        }

        try Data(#"{"url":"http://127.0.0.1:41937","port":41937,"token":"secret-tok"}"#.utf8).write(to: runtimeURL)

        await transport.enqueue(statusCode: 401, data: Data())
        await #expect(throws: TasksHubError.unauthorized) {
            _ = try await client.fetchTree(includeCompleted: false)
        }

        await transport.enqueueError(TasksHubError.unreachable)
        await #expect(throws: TasksHubError.unreachable) {
            _ = try await client.fetchTree(includeCompleted: false)
        }

        let treeData = Data(#"{"schema_version":2,"groups":[],"lists":[],"sections":[],"items":[]}"#.utf8)
        await transport.enqueue(statusCode: 200, data: treeData)
        let tree = try await client.fetchTree(includeCompleted: false)
        #expect(tree.schemaVersion == 2)

        await transport.enqueue(statusCode: 200, data: Data(#"{"ok":true}"#.utf8))
        try await client.setCompleted(itemID: "item-1", completed: true)

        await transport.enqueue(statusCode: 201, data: Data(#"{"ok":true}"#.utf8))
        try await client.createItem(title: "  测试新建待办  ", listID: "list-palboo")

        let recorded = await transport.recordedRequests()
        #expect(recorded.count == 5)
        let fetchReq = recorded[2]
        #expect(fetchReq.httpMethod == "GET")
        #expect(fetchReq.url?.absoluteString == "http://127.0.0.1:41937/api/reminders/tree?include_completed=false")
        #expect(fetchReq.value(forHTTPHeaderField: "Authorization") == "Bearer secret-tok")

        let patchReq = recorded[3]
        #expect(patchReq.httpMethod == "PATCH")
        #expect(patchReq.url?.absoluteString == "http://127.0.0.1:41937/api/reminders/items/item-1")
        let patchData = try #require(patchReq.httpBody)
        let patch = try #require(JSONSerialization.jsonObject(with: patchData) as? [String: Any])
        #expect(patch["completed"] as? Bool == true)
        #expect((patch["expected"] as? [String: Bool]) == ["completed": false])

        let postReq = recorded[4]
        #expect(postReq.httpMethod == "POST")
        #expect(postReq.url?.absoluteString == "http://127.0.0.1:41937/api/reminders/items")
        let bodyObj = try JSONSerialization.jsonObject(with: postReq.httpBody ?? Data()) as? [String: String]
        #expect(bodyObj?["title"] == "测试新建待办")
        #expect(bodyObj?["list_id"] == "list-palboo")
    }

    @Test("总览摘要文案格式化")
    func summaryFormatter() {
        #expect(TasksSummaryFormatter.statusText(state: .disabled) == "未启用")
        #expect(TasksSummaryFormatter.statusText(state: .connecting) == "连接中")
        #expect(TasksSummaryFormatter.statusText(state: .connected) == "Project")
        #expect(TasksSummaryFormatter.statusText(state: .offline) == "未连接")

        #expect(TasksSummaryFormatter.valueText(state: .connected, incompleteCount: 3) == "3 项未完成")
        #expect(TasksSummaryFormatter.valueText(state: .offline, incompleteCount: 3) == nil)
        #expect(
            TasksSummaryFormatter.overviewAccessibilityValue(state: .connected, incompleteCount: 3)
                == "待办 · 3 项未完成"
        )
        #expect(TasksSummaryFormatter.overviewAccessibilityValue(state: .offline, incompleteCount: 0) == "未连接")
    }
}

private actor MockTasksHubTransport: TasksHubTransport {
    private enum Outcome {
        case response(Int, Data)
        case failure(Error)
    }

    private var queue: [Outcome] = []
    private var requests: [URLRequest] = []

    func enqueue(statusCode: Int, data: Data) {
        queue.append(.response(statusCode, data))
    }

    func enqueueError(_ error: Error) {
        queue.append(.failure(error))
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queue.isEmpty else {
            throw TasksHubError.unreachable
        }
        switch queue.removeFirst() {
        case .response(let statusCode, let data):
            let url = request.url ?? URL(string: "http://127.0.0.1:41937")!
            let http = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (data, http)
        case .failure(let error):
            throw error
        }
    }
}
