// [INPUT]: 临时原图、受控 Eagle 回执、本机执行替身。
// [OUTPUT]: 收藏预检、全分页去重、原字节与元数据、并发写入保护回归。
// [POS]: 无真实音乐或素材库写入的收藏封面测试。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Darwin
import Foundation
import Testing

@testable import VorsmateSystem

@Suite("收藏封面系统侧")
struct MusicCoverArchiveTests {
    @Test("预检找不到文件夹时不创建文件夹、不导入")
    func noWriteInDryRun() async throws {
        let calls = Requests()
        let gate = Self.gate()
        let archive = MusicCoverArchive(gate: gate, read: Self.artwork) { request in
            await calls.append(request)
            return try Self.response(request, payload: ["data": []])
        }
        #expect(try await archive.archive(dryRun: true) == .preview("示例歌曲 - 示例歌手"))
        let captured = await calls.values
        #expect(captured.map { $0.url?.path } == ["/api/folder/list"])
        #expect(captured.allSatisfy { $0.httpMethod == "GET" })
        #expect(!FileManager.default.fileExists(atPath: gate.path))
    }

    @Test("正式收藏时创建缺失的文件夹，并使用创建回执中的 ID")
    func createsFolderOnlyForImport() async throws {
        let calls = Requests()
        let gate = Self.gate()
        defer { try? FileManager.default.removeItem(at: gate.deletingLastPathComponent()) }
        let archive = MusicCoverArchive(gate: gate, read: Self.artwork) { request in
            await calls.append(request)
            if request.url?.path == "/api/folder/list" {
                return try Self.response(request, payload: ["data": []])
            }
            let contents = try #require(request.httpBody)
            let data = try #require(JSONSerialization.jsonObject(with: contents) as? [String: Any])
            if request.url?.path == "/api/folder/create" {
                #expect(data["folderName"] as? String == "音乐封面")
                return try Self.response(request, payload: ["data": ["id": "created"]])
            }
            #expect(data["folderId"] as? String == "created")
            return try Self.response(request, payload: [:])
        }
        #expect(try await archive.archive() == .archived("示例歌曲 - 示例歌手"))
        let captured = await calls.values
        #expect(captured.map { $0.url?.path } == ["/api/folder/list", "/api/folder/create", "/api/item/addFromPath"])
    }

    @Test("完整分页，能拦截位于第 201 项的同专辑封面")
    func duplicateOnNextPage() async throws {
        let calls = Requests()
        let gate = Self.gate()
        defer { try? FileManager.default.removeItem(at: gate.deletingLastPathComponent()) }
        let archive = MusicCoverArchive(gate: gate, read: Self.artwork) { request in
            await calls.append(request)
            if request.url?.path == "/api/folder/list" { return try Self.folders(request) }
            let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
            let offset = query?.first(where: { $0.name == "offset" })?.value
            let items: [[String: String]]
            if offset == "0" {
                items = (0..<200).map { ["id": "cover-\($0)", "name": "其他歌曲 \($0)"] }
            } else {
                items = [["id": "older", "name": "同专辑其他曲目", "annotation": "歌手：示例歌手\n专辑：示例专辑"]]
            }
            return try Self.response(request, payload: ["data": items])
        }
        #expect(try await archive.archive() == .duplicate("示例歌曲 - 示例歌手"))
        let captured = await calls.values
        #expect(captured.map { $0.url?.path } == ["/api/folder/list", "/api/item/list", "/api/item/list"])
        #expect(captured.last?.url?.query?.contains("offset=200") == true)
    }

    @Test("相同前缀和已删除封面不误判；保留原字节和导入元数据")
    func importsOriginalAfterExactMatching() async throws {
        let calls = Requests()
        let gate = Self.gate()
        defer { try? FileManager.default.removeItem(at: gate.deletingLastPathComponent()) }
        let archive = MusicCoverArchive(gate: gate, read: Self.artwork) { request in
            await calls.append(request)
            switch request.url?.path {
            case "/api/folder/list": return try Self.folders(request)
            case "/api/item/list":
                return try Self.response(
                    request,
                    payload: [
                        "data": [
                            ["id": "prefix", "name": "相似歌曲", "annotation": "歌手：示例歌手甲\n专辑：示例专辑乙"],
                            ["id": "deleted", "name": "示例歌曲 - 示例歌手", "isDeleted": true],
                        ]
                    ])
            case "/api/item/addFromPath":
                let body = try #require(request.httpBody)
                let parameters = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let imagePath = try #require(parameters["path"] as? String)
                #expect(try Data(contentsOf: URL(fileURLWithPath: imagePath)) == Self.rawArtwork)
                #expect(parameters["folderId"] as? String == "target")
                #expect(parameters["name"] as? String == "示例歌曲 - 示例歌手")
                #expect(parameters["tags"] as? [String] == ["Apple Music", "示例歌手", "示例专辑"])
                #expect(parameters["annotation"] as? String == "歌曲：示例歌曲\n歌手：示例歌手\n专辑：示例专辑")
                return try Self.response(request, payload: [:])
            default: throw MusicCoverError.eagleResponse
            }
        }
        #expect(try await archive.archive() == .archived("示例歌曲 - 示例歌手"))
        let captured = await calls.values
        #expect(captured.last?.httpMethod == "POST")
        let body = try #require(captured.last?.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let imagePath = try #require(fields["path"] as? String)
        #expect(!FileManager.default.fileExists(atPath: imagePath))
    }

    @Test("收藏互斥锁繁忙时不发起 Eagle 请求")
    func busyGateStopsBeforeEagle() async throws {
        let calls = Requests()
        let gate = Self.gate()
        let folder = gate.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fd = open(gate.path, O_CREAT | O_RDWR, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let archive = MusicCoverArchive(gate: gate, read: Self.artwork) { request in
            await calls.append(request)
            return try Self.response(request, payload: ["data": []])
        }
        await #expect(throws: MusicCoverError.busy) { try await archive.archive() }
        #expect(await calls.values.isEmpty)
    }

    private actor Requests {
        private(set) var values: [URLRequest] = []
        func append(_ request: URLRequest) { values.append(request) }
    }

    private static let rawArtwork = Data([137, 80, 78, 71, 13, 10, 26, 10])

    private static func gate() -> URL {
        URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "operation.lock")
    }

    private static func artwork(_ folder: URL) async throws -> MusicCoverArtwork {
        let file = folder.appending(path: "original.png")
        try rawArtwork.write(to: file)
        return MusicCoverArtwork(file: file, track: "示例歌曲", artist: "示例歌手", album: "示例专辑")
    }

    private static func folders(_ request: URLRequest) throws -> (Data, URLResponse) {
        try response(
            request,
            payload: [
                "data": [["id": "root", "name": "测试图库", "children": [["id": "target", "name": "音乐封面"]]]]
            ])
    }

    private static func response(_ request: URLRequest, payload: [String: Any]) throws -> (Data, URLResponse) {
        var fields = payload
        fields["status"] = "success"
        let url = try #require(request.url)
        #expect(url.host == "127.0.0.1" && url.port == 41595)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONSerialization.data(withJSONObject: fields), response)
    }
}
