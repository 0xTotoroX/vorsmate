// [INPUT]: 官方固定更新源、版本和安装包地址；不读取用户配置。
// [OUTPUT]: 固定签名 feed 地址、官方安装包校验与语义版本规则。
// [POS]: 更新来源的纯规则；feed 解析、版本选择及双重签名验证交由 Sparkle。
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

public enum UpdatePolicy {
    public static let feedURL = URL(string: "https://raw.githubusercontent.com/0xTotoroX/vorsmate/updates/appcast.xml")!
    public static let releaseURL = URL(string: "https://github.com/0xTotoroX/vorsmate/releases")!

    public static func accepts(downloadURL: URL?, version: String) -> Bool {
        guard ReleaseVersion(version) != nil, let address = downloadURL?.absoluteString else { return false }
        let base = "https://github.com/0xTotoroX/vorsmate/releases/download/v\(version)/Vorsmate-\(version)"
        return address == "\(base).dmg" || address == "\(base)-universal.dmg"
    }
}
