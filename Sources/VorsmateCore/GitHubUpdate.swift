// [INPUT]: GitHub Releases JSON 与本机版本；不读取用户配置。
// [OUTPUT]: 语义版本比较及固定官方仓库的最新 Universal 更新信息。
// [POS]: 更新发现的纯规则；下载、签名验证和安装交由 Sparkle。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct ReleaseVersion: Comparable, Sendable {
    private let numbers: [UInt]
    private let prerelease: [String]

    public init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let metadata = value.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        func identifiers(_ value: Substring) -> [String]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard
                parts.allSatisfy({
                    !$0.isEmpty
                        && $0.utf8.allSatisfy {
                            $0 == 45 || (48...57).contains($0) || (65...90).contains($0)
                                || (97...122).contains($0)
                        }
                })
            else { return nil }
            return parts
        }
        if metadata.count == 2, identifiers(metadata[1]) == nil { return nil }
        let main = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = main[0].split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { UInt($0) }
        guard components.count == 3, numbers.count == 3,
            components.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") })
        else { return nil }
        var prerelease: [String] = []
        if main.count == 2 {
            guard let parts = identifiers(main[1]),
                parts.allSatisfy({ !Self.isNumeric($0) || $0 == "0" || !$0.hasPrefix("0") })
            else { return nil }
            prerelease = parts
        }
        self.numbers = numbers
        self.prerelease = prerelease
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            if isNumeric(left), isNumeric(right) {
                return left.count == right.count ? left < right : left.count < right.count
            }
            if isNumeric(left) { return true }
            if isNumeric(right) { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func isNumeric(_ value: String) -> Bool { value.utf8.allSatisfy { (48...57).contains($0) } }
}

public struct GitHubUpdate: Equatable, Sendable {
    public static let releasesURL = URL(
        string: "https://api.github.com/repos/0xTotoroX/vorsmate/releases?per_page=100")!
    public let version: String
    public let releaseURL: URL
    public let feedURL: URL?
    public let downloadURL: URL

    /// 从发布列表按版本比较，不让 /latest 的返回范围替代版本过滤。
    public static func latest(in data: Data, newerThan current: String) throws -> Self? {
        struct Asset: Decodable {
            let name: String
            let downloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
        struct Release: Decodable {
            let tag: String
            let draft: Bool
            let assets: [Asset]
            enum CodingKeys: String, CodingKey {
                case tag = "tag_name"
                case draft, assets
            }
        }
        guard let installed = ReleaseVersion(current) else { throw CocoaError(.coderInvalidValue) }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> (ReleaseVersion, Self)? in
            guard !release.draft, let parsed = ReleaseVersion(release.tag), parsed > installed else { return nil }
            let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            let prefix = "https://github.com/0xTotoroX/vorsmate/releases/download/\(release.tag)/"
            let filename = "Vorsmate-\(version)-universal.dmg"
            guard
                let download = release.assets.first(where: {
                    $0.name == filename && $0.downloadURL.absoluteString == prefix + filename
                })
            else { return nil }
            let feed = release.assets.first {
                $0.name == "appcast.xml" && $0.downloadURL.absoluteString == prefix + "appcast.xml"
            }
            return (
                parsed,
                Self(
                    version: version,
                    releaseURL: URL(string: "https://github.com/0xTotoroX/vorsmate/releases/tag/\(release.tag)")!,
                    feedURL: feed?.downloadURL, downloadURL: download.downloadURL)
            )
        }.max { $0.0 < $1.0 }?.1
    }
}
