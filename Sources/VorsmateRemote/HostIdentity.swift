// [INPUT]: 内核提供的父进程 PID、本插件与宿主的签名和位置。
// [OUTPUT]: 配套宿主是否可开启后台监听。
// [POS]: 子进程校验父进程；公开验收入口始终显示独立窗口。
import AppKit
import Security

enum HostIdentity {
    static func acceptsParent() -> Bool {
        let pid = getppid()
        guard let parent = NSRunningApplication(processIdentifier: pid),
            let url = parent.bundleURL?.resolvingSymlinksInPath(),
            url.path
                == Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().appending(
                    path: "Vorsmate.app"
                ).path,
            parent.bundleIdentifier == "app.vorsmate.mac"
        else { return false }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else {
            return false
        }
        var own: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &own) == errSecSuccess, let own,
            SecCodeCopySigningInformation(own, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let signature = info as? [String: Any]
        else { return false }
        var rule = "identifier \"app.vorsmate.mac\""
        if let team = signature[kSecCodeInfoTeamIdentifier as String] as? String {
            rule += " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        } else {
            guard let data = signature[kSecCodeInfoUnique as String] as? Data,
                let pins = Bundle(url: url)?.object(forInfoDictionaryKey: "VorsmateRemoteDevelopmentHashes")
                    as? [String],
                pins.contains(data.map { String(format: "%02x", $0) }.joined())
            else { return false }
        }
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
            && SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}
