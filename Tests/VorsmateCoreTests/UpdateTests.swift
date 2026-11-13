// [INPUT]: 合成发布列表及语义版本；不访问网络、硬件或配置。
// [OUTPUT]: 发布发现、防止降级与非官方资产、旧发布兼容的规则回归。
// [POS]: GitHubUpdate 纯规则测试，实际安装另由隔离 Sparkle 预览验收。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore

@Suite("更新发现")
struct UpdateTests {
    private func release(_ version: String, draft: Bool = false, feed: Bool = true) -> [String: Any] {
        let tag = "v\(version)"
        let prefix = "https://github.com/0xTotoroX/vorsmate/releases/download/\(tag)/"
        var assets = [
            [
                "name": "Vorsmate-\(version)-universal.dmg",
                "browser_download_url": prefix + "Vorsmate-\(version)-universal.dmg",
            ]
        ]
        if feed { assets.append(["name": "appcast.xml", "browser_download_url": prefix + "appcast.xml"]) }
        return ["tag_name": tag, "draft": draft, "prerelease": true, "assets": assets]
    }
    private func data(_ releases: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: releases)
    }

    @Test("数字版本参与选择，按版本而不是 GitHub 返回顺序取最新")
    func previewRelease() throws {
        let update = try GitHubUpdate.latest(
            in: data([release("0.3.0"), release("8.0.0", draft: true), release("0.10.0"), release("0.2.0")]),
            newerThan: "0.2.0")
        #expect(update?.version == "0.10.0")
        #expect(update?.feedURL?.absoluteString.hasSuffix("/v0.10.0/appcast.xml") == true)
    }

    @Test("相同及较旧版本不提示，不降级", arguments: ["0.2.0", "v0.2.0", "0.3.0", "0.2.0+local"])
    func noDowngrade(current: String) throws {
        #expect(try GitHubUpdate.latest(in: data([release("0.1.2"), release("0.2.0")]), newerThan: current) == nil)
    }

    @Test("旧发布没有签名 feed 时仍能指向发布页，不伪装成可自动安装")
    func legacyRelease() throws {
        let update = try GitHubUpdate.latest(in: data([release("0.3.0", feed: false)]), newerThan: "0.2.0")
        #expect(update?.version == "0.3.0")
        #expect(update?.feedURL == nil)
        #expect(update?.releaseURL.absoluteString == "https://github.com/0xTotoroX/vorsmate/releases/tag/v0.3.0")
    }

    @Test(
        "外部仓库或伪装资产不作为可安装版本",
        arguments: [
            "http://github.com/0xTotoroX/vorsmate/releases/download/v0.3.0/",
            "https://github.com.evil.example/0xTotoroX/vorsmate/releases/download/v0.3.0/",
            "https://github.com/another/repo/releases/download/v0.3.0/",
            "https://github.com/0xTotoroX/vorsmate/releases/download/v0.2.0/",
        ])
    func foreignArchive(prefix: String) throws {
        var value = release("0.3.0")
        value["assets"] = [
            ["name": "Vorsmate-0.3.0-universal.dmg", "browser_download_url": prefix + "Vorsmate-0.3.0-universal.dmg"]
        ]
        #expect(try GitHubUpdate.latest(in: data([value]), newerThan: "0.2.0") == nil)
    }

    @Test("语义版本遵循候选顺序和元数据规则")
    func versions() {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
            "1.0.0-rc.1", "1.0.0", "1.9.0", "1.10.0",
        ]
        let values = ordered.compactMap(ReleaseVersion.init)
        #expect(values.count == ordered.count)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        #expect(ReleaseVersion("v1.0.0+build.7") == ReleaseVersion("1.0.0"))
        #expect(ReleaseVersion("1.0.0-999999999999999999999999999999")! < ReleaseVersion("1.0.0-a")!)
    }

    @Test(
        "异常版本和路径不参与更新",
        arguments: [
            "", "main", "1.2", "01.2.3", "1.2.3-", "1.2.3-01", "1.2.3+", "1.2.3-../../x", "1.2.3-α", "1.2.3+a+b",
        ])
    func invalidVersion(value: String) { #expect(ReleaseVersion(value) == nil) }

    @Test("无发布、无安装包和损坏响应安全结束")
    func emptyAndInvalid() throws {
        #expect(try GitHubUpdate.latest(in: data([]), newerThan: "0.2.0") == nil)
        #expect(throws: (any Error).self) { try GitHubUpdate.latest(in: Data("not JSON".utf8), newerThan: "0.2.0") }
        #expect(throws: (any Error).self) { try GitHubUpdate.latest(in: data([]), newerThan: "dev") }
    }
}
