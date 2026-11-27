// [INPUT]: Security 本机非同步钥匙串 API 与 OpenDirectory 本地账户口令核验。
// [OUTPUT]: 密码存储 / 校验协议、Keychain / OpenDirectory 实现及内存与固定值测试替身。
// [POS]: VorsmateSystem 无人值守授权凭证层；密码不上云、不写日志，仅由控制器与驱动边界调用。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import OpenDirectory
import Security

public enum UnattendedAuthPasswordVerification: Equatable, Sendable {
    case valid
    case invalid
    case unavailable(String)
}

public protocol UnattendedAuthPasswordStore: Sendable {
    func hasPassword() -> Bool
    func loadPassword() throws -> String?
    func savePassword(_ password: String) throws
    func deletePassword() throws
}

public protocol UnattendedAuthPasswordVerifier: Sendable {
    func verifyPassword(_ password: String) -> UnattendedAuthPasswordVerification
}

public enum UnattendedAuthKeychainError: LocalizedError {
    case status(OSStatus)
    case invalidEncoding

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "钥匙串操作失败：\(message)（\(status)）"
            }
            return "钥匙串操作失败（\(status)）"
        case .invalidEncoding:
            return "无法解析钥匙串中保存的密码。"
        }
    }
}

public struct KeychainUnattendedPasswordStore: UnattendedAuthPasswordStore {
    private let service: String
    private let account: String

    public init(
        service: String = "app.vorsmate.mac.unattended-auth",
        account: String = "admin-password"
    ) {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func hasPassword() -> Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func loadPassword() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw UnattendedAuthKeychainError.status(status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw UnattendedAuthKeychainError.invalidEncoding
        }
        return password
    }

    public func savePassword(_ password: String) throws {
        let data = Data(password.utf8)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Vorsmate 无人值守授权密码",
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw UnattendedAuthKeychainError.status(updateStatus)
        }
        var addQuery = query
        for (key, value) in attributes { addQuery[key] = value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw UnattendedAuthKeychainError.status(addStatus)
        }
    }

    public func deletePassword() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw UnattendedAuthKeychainError.status(status)
        }
    }
}

public struct OpenDirectoryPasswordVerifier: UnattendedAuthPasswordVerifier {
    public init() {}

    public func verifyPassword(_ password: String) -> UnattendedAuthPasswordVerification {
        guard !password.isEmpty else { return .invalid }
        do {
            let session = ODSession.default()
            let node = try ODNode(session: session, type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return .valid
        } catch let error as NSError {
            if error.domain == ODFrameworkErrorDomain
                && error.code == Int(kODErrorCredentialsInvalid.rawValue)
            {
                return .invalid
            }
            return .unavailable("无法核验本机账户密码：\(error.localizedDescription)")
        }
    }
}

public final class InMemoryUnattendedPasswordStore: UnattendedAuthPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    public init(initialPassword: String? = nil) {
        stored = initialPassword
    }

    public func hasPassword() -> Bool {
        lock.withLock { stored != nil }
    }

    public func loadPassword() throws -> String? {
        lock.withLock { stored }
    }

    public func savePassword(_ password: String) throws {
        lock.withLock { stored = password }
    }

    public func deletePassword() throws {
        lock.withLock { stored = nil }
    }
}

public struct FixedPasswordVerifier: UnattendedAuthPasswordVerifier {
    private let expected: String?

    public init(expected: String? = nil) {
        self.expected = expected
    }

    public func verifyPassword(_ password: String) -> UnattendedAuthPasswordVerification {
        guard !password.isEmpty else { return .invalid }
        guard let expected else { return .valid }
        return password == expected ? .valid : .invalid
    }
}
