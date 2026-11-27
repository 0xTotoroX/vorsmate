// [INPUT]: 已签名 appcast、应用公钥和可选发行安装包。
// [OUTPUT]: feed 签名、版本与载荷签名 / 长度核验；只使用公钥，不访问钥匙串。
// [POS]: 固定更新源发布前的本地验收；不上传、不改写 feed 或应用。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw NSError(domain: "Vorsmate.VerifyUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
func verify() throws {
    try require(
        (3...4).contains(arguments.count), "Usage: swift scripts/verify-update.swift appcast.xml Vorsmate.app [archive]"
    )
    let infoURL = URL(fileURLWithPath: arguments[2]).appendingPathComponent("Contents/Info.plist")
    let info =
        try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
    guard let encodedKey = info?["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: encodedKey) else {
        throw CocoaError(.propertyListReadCorrupt)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let feed = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    guard let range = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards) else {
        throw NSError(
            domain: "Vorsmate.VerifyUpdate", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Missing feed signature"])
    }
    let content = feed.prefix(range.lowerBound)
    let lines = String(decoding: feed.suffix(from: range.lowerBound), as: UTF8.self).split(separator: "\n").map(
        String.init)
    let signatureLines = lines.filter { $0.hasPrefix("edSignature: ") }
    let lengthLines = lines.filter { $0.hasPrefix("length: ") }
    try require(signatureLines.count == 1 && lengthLines.count == 1, "Expected single feed signature and length line")
    guard let signatureLine = signatureLines.first,
        let lengthLine = lengthLines.first,
        let signature = Data(base64Encoded: String(signatureLine.dropFirst("edSignature: ".count))),
        let length = Int(lengthLine.dropFirst("length: ".count))
    else { throw CocoaError(.fileReadCorruptFile) }
    try require(
        length == content.count && key.isValidSignature(signature, for: content), "Invalid feed signature or length")
    let document = try XMLDocument(data: content)
    let items = try document.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Expected one release item")
    let item = items[0]
    let version = try item.nodes(forXPath: "sparkle:shortVersionString").first?.stringValue
    let build = try item.nodes(forXPath: "sparkle:version").first?.stringValue
    try require(version == info?["CFBundleShortVersionString"] as? String, "Feed and app versions differ")
    try require(build == info?["CFBundleVersion"] as? String, "Feed and app build numbers differ")
    if arguments.count == 4 {
        let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
        guard let enclosure = try item.nodes(forXPath: "enclosure").first as? XMLElement,
            let encoded = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
            let archiveSignature = Data(base64Encoded: encoded),
            let count = enclosure.attribute(forName: "length")?.stringValue.flatMap(Int.init)
        else { throw CocoaError(.fileReadCorruptFile) }
        try require(
            count == archive.count && key.isValidSignature(archiveSignature, for: archive),
            "Invalid archive signature or length")
    }
    print("Verified signed feed and release metadata\(arguments.count == 4 ? " with archive signature" : "").")
}
do { try verify() } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
