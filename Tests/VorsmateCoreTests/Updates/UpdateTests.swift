// [INPUT]: 官方固定更新源、安装包地址及语义版本；不访问网络或配置。
// [OUTPUT]: 官方包匹配、预发布版本及异常路径拒绝回归。
// [POS]: 更新来源策略测试；feed / 安装包双重验签另由 Sparkle 完整流程验收。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore

@Suite("更新来源")
struct UpdateTests {
    @Test("正式与预发布版本接受官方新旧安装包命名", arguments: ["0.3.1", "0.3.2-beta.1"])
    func officialPackage(version: String) {
        for suffix in ["", "-universal"] {
            let url = URL(
                string:
                    "https://github.com/0xTotoroX/vorsmate/releases/download/v\(version)/Vorsmate-\(version)\(suffix).dmg"
            )!
            #expect(UpdatePolicy.accepts(downloadURL: url, version: version))
            #expect(!UpdatePolicy.accepts(downloadURL: url, version: "0.3.0"))
        }
        #expect(!UpdatePolicy.accepts(downloadURL: nil, version: version))
    }
    @Test(
        "外部仓库、伪装域名、不安全协议与异常资产不能安装",
        arguments: [
            "http://github.com/0xTotoroX/vorsmate/releases/download/v0.3.1/Vorsmate-0.3.1-universal.dmg",
            "https://github.com.evil.example/0xTotoroX/vorsmate/releases/download/v0.3.1/Vorsmate-0.3.1-universal.dmg",
            "https://github.com/another/repo/releases/download/v0.3.1/Vorsmate-0.3.1-universal.dmg",
            "https://github.com/0xTotoroX/vorsmate/releases/download/v0.3.1/Vorsmate-0.3.1-universal.dmg?redirect=elsewhere",
            "http://github.com/0xTotoroX/vorsmate/releases/download/v0.3.1/Vorsmate-0.3.1.dmg",
            "https://github.com.evil.example/0xTotoroX/vorsmate/releases/download/v0.3.1/Vorsmate-0.3.1.dmg",
            "https://github.com/another/repo/releases/download/v0.3.1/Vorsmate-0.3.1.dmg",
            "https://github.com/0xTotoroX/vorsmate/releases/download/v0.3.1/Vorsmate-0.3.1.dmg?redirect=elsewhere",
            "https://github.com/0xTotoroX/vorsmate/releases/download/v0.3.1/Vorsmate-0.3.1.dmg#download",
            "https://github.com/0xTotoroX/vorsmate/releases/download/v0.3.1/Vorsmate-0.3.0.dmg",
            "https://github.com/0xTotoroX/vorsmate/releases/download/v0.3.1/other.dmg",
        ])
    func foreignPackage(address: String) {
        #expect(!UpdatePolicy.accepts(downloadURL: URL(string: address), version: "0.3.1"))
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

}
