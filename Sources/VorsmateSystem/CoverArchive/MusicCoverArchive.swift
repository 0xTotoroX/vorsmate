// [INPUT]: Apple Music 原始封面读取器与 Eagle 本机回环接口。
// [OUTPUT]: 按文件夹分页去重、保留歌曲和专辑信息的封面收藏结果。
// [POS]: 视频和内容工作流之外的独立收藏适配器。预检不写 Eagle。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Darwin
import Foundation

public enum MusicCoverResult: Equatable, Sendable {
    case archived(String)
    case duplicate(String)
    case preview(String)
}

public enum MusicCoverError: LocalizedError, Equatable, Sendable {
    case musicNotRunning
    case musicPermissionRequired
    case musicReadFailed
    case noTrack
    case noArtwork
    case eagleUnavailable
    case eagleResponse
    case busy
    case localStorage

    public var errorDescription: String? {
        switch self {
        case .musicNotRunning: "请先打开 Apple Music，播放或选中一首歌。"
        case .musicPermissionRequired: "请在系统设置的「自动化」中允许 Vorsmate 访问“音乐”。"
        case .musicReadFailed: "暂时无法读取当前歌曲的封面。"
        case .noTrack: "当前没有正在播放或选中的歌曲。"
        case .noArtwork: "当前歌曲没有可读取的封面。"
        case .eagleUnavailable: "请打开 Eagle 并载入素材库。"
        case .eagleResponse: "Eagle 未能完成请求，请检查当前素材库。"
        case .busy: "另一次封面收藏正在进行。"
        case .localStorage: "暂时无法准备封面文件。"
        }
    }
}

public struct MusicCoverArchive: Sendable {
    typealias Read = @Sendable (URL) async throws -> MusicCoverArtwork
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private static let defaultGate = URL.applicationSupportDirectory
        .appending(path: "Vorsmate/CoverArchive/operation.lock")
    private static let folder = "音乐封面"
    private static let pageSize = 200
    private let gate: URL
    private let read: Read
    private let send: Send

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(
            configuration: configuration, delegate: LocalHTTPRedirectGuard(), delegateQueue: nil)
        self.init(gate: Self.defaultGate, read: MusicCoverReader.read, send: { try await session.data(for: $0) })
    }

    init(gate: URL, read: @escaping Read, send: @escaping Send) {
        self.gate = gate
        self.read = read
        self.send = send
    }

    public func archive(dryRun: Bool = false) async throws -> MusicCoverResult {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "VorsmateCover-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw MusicCoverError.localStorage
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let artwork = try await read(directory)
        let metadata = CoverMetadata(artwork)
        let lock = dryRun ? nil : try acquireGate()
        defer { if let lock { close(lock) } }
        let existing = try await folderID()
        if let existing, try await hasDuplicate(metadata, in: existing) {
            return .duplicate(metadata.name)
        }
        if dryRun { return .preview(metadata.name) }
        let folder = if let existing { existing } else { try await createFolder() }
        _ = try await request(
            "item/addFromPath",
            body: Import(
                path: metadata.file.path, name: metadata.name, annotation: metadata.annotation,
                tags: metadata.tags, folderId: folder))
        return .archived(metadata.name)
    }

    private func acquireGate() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: gate.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw MusicCoverError.localStorage
        }
        let fd = open(gate.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MusicCoverError.localStorage }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        let busy = errno == EWOULDBLOCK
        close(fd)
        throw busy ? MusicCoverError.busy : MusicCoverError.localStorage
    }

    private func folderID() async throws -> String? {
        let folders = try parse([Folder].self, from: await request("folder/list"))
        return folders.lazy.compactMap { $0.find(named: Self.folder) }.first
    }

    private func createFolder() async throws -> String {
        let created = try parse(
            CreatedFolder.self,
            from: await request(
                "folder/create", body: CreateFolder(folderName: Self.folder)))
        guard !created.id.isEmpty else { throw MusicCoverError.eagleResponse }
        return created.id
    }

    private func hasDuplicate(_ candidate: CoverMetadata, in folder: String) async throws -> Bool {
        var offset = 0
        var seen: Set<String> = []
        while true {
            let query = [
                URLQueryItem(name: "folders", value: folder),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            let items = try parse([Item].self, from: await request("item/list", query: query))
            if items.contains(where: candidate.matches) { return true }
            if items.count < Self.pageSize { return false }
            let count = seen.count
            seen.formUnion(items.map(\.id))
            guard seen.count > count else { throw MusicCoverError.eagleResponse }
            offset += items.count
        }
    }

    private func request(
        _ route: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 41595
        components.path = "/api/\(route)"
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw MusicCoverError.eagleResponse }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let payload: Data
        let response: URLResponse
        do {
            (payload, response) = try await send(request)
        } catch {
            throw MusicCoverError.eagleUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            (try? JSONDecoder().decode(Status.self, from: payload))?.status == "success"
        else { throw MusicCoverError.eagleResponse }
        return payload
    }

    private func parse<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard let response = try? JSONDecoder().decode(Payload<Value>.self, from: data) else {
            throw MusicCoverError.eagleResponse
        }
        return response.data
    }

    private struct Status: Decodable { let status: String }
    private struct Payload<Value: Decodable>: Decodable { let data: Value }
    private struct CreateFolder: Encodable { let folderName: String }
    private struct CreatedFolder: Decodable { let id: String }
    private struct Folder: Decodable {
        let id: String
        let name: String
        let children: [Folder]?

        func find(named target: String) -> String? {
            if name == target, !id.isEmpty { return id }
            return children?.lazy.compactMap { $0.find(named: target) }.first
        }
    }
    private struct Item: Decodable {
        let id: String
        let name: String
        let annotation: String?
        let isDeleted: Bool?
    }
    private struct Import: Encodable {
        let path: String
        let name: String
        let annotation: String
        let tags: [String]
        let folderId: String
    }

    private struct CoverMetadata {
        let file: URL
        let track: String
        let artist: String
        let album: String

        init(_ artwork: MusicCoverArtwork) {
            file = artwork.file
            track = artwork.track.trimmingCharacters(in: .whitespacesAndNewlines)
            artist = artwork.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            album = artwork.album.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var name: String {
            if !track.isEmpty, !artist.isEmpty { return "\(track) - \(artist)" }
            if !track.isEmpty { return track }
            return album.isEmpty ? "Apple Music 封面" : album
        }

        var tags: [String] {
            var tags = ["Apple Music"]
            for tag in [artist, album] where !tag.isEmpty && !tags.contains(tag) { tags.append(tag) }
            return tags
        }

        var annotation: String {
            [("歌曲", track), ("歌手", artist), ("专辑", album)]
                .filter { !$0.1.isEmpty }.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
        }

        func matches(_ existing: Item) -> Bool {
            guard existing.isDeleted != true else { return false }
            if existing.name.trimmingCharacters(in: .whitespacesAndNewlines) == name { return true }
            guard !artist.isEmpty, !album.isEmpty, let annotation = existing.annotation else { return false }
            let lines = annotation.split(whereSeparator: \.isNewline)
            return lines.contains("歌手：\(artist)") && lines.contains("专辑：\(album)")
        }
    }
}
