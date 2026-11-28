// [INPUT]: Foundation 日期、Codable 与 Preferences 同目录文件锁。
// [OUTPUT]: 无人值守授权的弹窗分类（含软件权限许可）、截止时间策略、状态文案格式化、脱敏活动记录与本地有界存储。
// [POS]: VorsmateCore 纯数据与规则层；不持有密码、不访问辅助功能或系统通知。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum UnattendedAuthPolicy {
    public static let maxCustomMinutes = 1440
}

public enum UnattendedAuthDialogCategory: String, Codable, Equatable, Sendable {
    case systemAdmin
    case privacySettings
    case appPermissions
    case credentialAndAppAuth
}

public struct UnattendedAuthPreferences: Codable, Equatable, Sendable {
    public var approvePrivacySettings = true
    public var approveAppPermissions = true
    public var approveCredentialAndAppAuth = true
    public var approveExistingDialogs = true

    public init(
        approvePrivacySettings: Bool = true,
        approveAppPermissions: Bool = true,
        approveCredentialAndAppAuth: Bool = true,
        approveExistingDialogs: Bool = true
    ) {
        self.approvePrivacySettings = approvePrivacySettings
        self.approveAppPermissions = approveAppPermissions
        self.approveCredentialAndAppAuth = approveCredentialAndAppAuth
        self.approveExistingDialogs = approveExistingDialogs
    }

    private enum CodingKeys: String, CodingKey {
        case approvePrivacySettings
        case approveAppPermissions
        case approveCredentialAndAppAuth
        case approveExistingDialogs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        approvePrivacySettings = try values.decodeIfPresent(Bool.self, forKey: .approvePrivacySettings) ?? true
        approveAppPermissions = try values.decodeIfPresent(Bool.self, forKey: .approveAppPermissions) ?? true
        approveCredentialAndAppAuth =
            try values.decodeIfPresent(Bool.self, forKey: .approveCredentialAndAppAuth) ?? true
        approveExistingDialogs = try values.decodeIfPresent(Bool.self, forKey: .approveExistingDialogs) ?? true
    }

    public func manualConfirmationReason(for category: UnattendedAuthDialogCategory, isExisting: Bool) -> String? {
        if isExisting && !approveExistingDialogs {
            return "开启前已存在的请求由本人确认"
        }
        switch category {
        case .systemAdmin:
            return nil
        case .privacySettings:
            return approvePrivacySettings ? nil : "隐私与安全请求由本人确认"
        case .appPermissions:
            return approveAppPermissions ? nil : "软件权限许可请求由本人确认"
        case .credentialAndAppAuth:
            return approveCredentialAndAppAuth ? nil : "密码与通行密钥请求由本人确认"
        }
    }

    public var optionsSummaryText: String {
        let enabledCount = [
            approvePrivacySettings,
            approveAppPermissions,
            approveCredentialAndAppAuth,
            approveExistingDialogs,
        ]
        .filter(\.self)
        .count
        if enabledCount == 4 { return "全部" }
        if enabledCount == 0 { return "仅常规管理员" }
        return "已选 \(enabledCount)/4"
    }
}

public enum UnattendedAuthDeadlineChoice: Equatable, Sendable {
    public static let maxCustomMinutes = UnattendedAuthPolicy.maxCustomMinutes
    case none
    case durationMinutes(Int)
    case specificDate(Date)

    public func resolveDeadline(from now: Date) -> Date? {
        switch self {
        case .none:
            return nil
        case .durationMinutes(let minutes):
            guard (1...Self.maxCustomMinutes).contains(minutes) else { return nil }
            let (seconds, overflow) = minutes.multipliedReportingOverflow(by: 60)
            guard !overflow else { return nil }
            return now.addingTimeInterval(TimeInterval(seconds))
        case .specificDate(let date):
            guard date > now else { return nil }
            return date
        }
    }

    public var requiresFutureDeadline: Bool {
        if case .none = self { return false }
        return true
    }
}

public enum UnattendedAuthEventOutcome: String, Codable, Equatable, Sendable {
    case approved
    case blocked
    case leftForUser
    case passwordInvalid

    public var title: String {
        switch self {
        case .approved: "已自动批准"
        case .blocked: "自动批准受阻，保留本人确认"
        case .leftForUser: "保留本人确认"
        case .passwordInvalid: "密码失效，已自动关闭"
        }
    }
}

public enum UnattendedAuthStopReason: String, Codable, Equatable, Sendable {
    case manual
    case deadlineReached
    case passwordInvalid
    case passwordDeleted
    case pluginDisabled
    case appTerminated

    public var title: String {
        switch self {
        case .manual: "手动关闭"
        case .deadlineReached: "到达截止时间"
        case .passwordInvalid: "密码失效"
        case .passwordDeleted: "密码已删除"
        case .pluginDisabled: "模块已停用"
        case .appTerminated: "应用退出"
        }
    }
}

public struct UnattendedAuthDialogEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let source: String
    public let summary: String
    public let outcome: UnattendedAuthEventOutcome
    public let detail: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        source: String,
        summary: String,
        outcome: UnattendedAuthEventOutcome,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.summary = summary
        self.outcome = outcome
        self.detail = detail
    }
}

public struct UnattendedAuthSessionRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public let deadline: Date?
    public var stopReason: UnattendedAuthStopReason?
    public var events: [UnattendedAuthDialogEvent]

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        deadline: Date? = nil,
        stopReason: UnattendedAuthStopReason? = nil,
        events: [UnattendedAuthDialogEvent] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.deadline = deadline
        self.stopReason = stopReason
        self.events = events
    }
}

public enum UnattendedAuthSanitizer {
    public static let maxSummaryLength = 140

    public static func sanitizeText(_ raw: String, excludingSecret secret: String? = nil) -> String {
        var cleaned =
            raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if let secret, !secret.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: secret, with: "")
        }
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maxSummaryLength else { return collapsed }
        return String(collapsed.prefix(maxSummaryLength - 1)) + "…"
    }

    public static func extractRequester(from promptText: String, fallback: String) -> String {
        let text = sanitizeText(promptText)
        let markers = [
            " 想要", "想要进行更改", "想要安装", "想要修改", "想访问", "想修改", "想使用", "想控制",
            "正试图", "试图", " wants to ", " is trying to ", " would like to ",
        ]
        for marker in markers {
            if let range = text.range(of: marker) {
                let prefix = text[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " “”\"'「」『』"))
                if !prefix.isEmpty && prefix.count <= 48 {
                    return prefix
                }
            }
        }
        let quotedPrefixes: [(prefix: String, closing: Character, caseInsensitive: Bool)] = [
            ("允许“", "”", false),
            ("允许\"", "\"", false),
            ("Allow “", "”", true),
            ("Allow \"", "\"", true),
        ]
        for item in quotedPrefixes {
            let options: String.CompareOptions = item.caseInsensitive ? [.caseInsensitive] : []
            if let start = text.range(of: item.prefix, options: options),
                let end = text[start.upperBound...].firstIndex(of: item.closing)
            {
                let quoted = text[start.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if !quoted.isEmpty && quoted.count <= 48 {
                    return quoted
                }
            }
        }
        return fallback.isEmpty ? "系统授权请求" : fallback
    }
}

public enum UnattendedAuthStatusFormatter {
    public static func fullStatus(
        isEnabled: Bool,
        deadline: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        guard isEnabled else { return "已关闭" }
        guard let deadline else { return "无人值守授权已开启 · 手动关闭" }
        let clock = deadlineClockText(deadline, now: now, calendar: calendar)
        let remaining = remainingText(until: deadline, now: now)
        return "无人值守授权已开启 · 至 \(clock)（\(remaining)）"
    }

    public static func menuBarTitle(
        isEnabled: Bool,
        deadline: Date?,
        now: Date
    ) -> String? {
        guard isEnabled else { return nil }
        guard let deadline else { return "无人值守" }
        return "无人值守 · \(remainingText(until: deadline, now: now))"
    }

    public static func summaryStatus(
        isEnabled: Bool,
        hasSavedPassword: Bool,
        passwordInvalidated: Bool,
        deadline: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        if isEnabled {
            if let deadline {
                return "已开启 · 至 \(deadlineClockText(deadline, now: now, calendar: calendar))"
            }
            return "已开启 · 手动关闭"
        }
        if passwordInvalidated { return "密码已失效" }
        if !hasSavedPassword { return "未配置密码" }
        return "已关闭"
    }

    public static func summaryValue(
        isEnabled: Bool,
        passwordInvalidated: Bool,
        deadline: Date?,
        now: Date
    ) -> String {
        if isEnabled {
            if let deadline {
                return remainingText(until: deadline, now: now)
            }
            return "运行中"
        }
        if passwordInvalidated { return "需更新" }
        return "未开启"
    }

    public static func deadlineClockText(_ deadline: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(deadline, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: deadline)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
            calendar.isDate(deadline, inSameDayAs: tomorrow)
        {
            formatter.dateFormat = "HH:mm"
            return "明日 \(formatter.string(from: deadline))"
        }
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: deadline)
    }

    public static func remainingText(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        if seconds < 60 {
            return "剩余 \(seconds) 秒"
        }
        let minutes = Int(ceil(deadline.timeIntervalSince(now) / 60))
        if minutes < 60 {
            return "剩余 \(minutes) 分钟"
        }
        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        if remainderMinutes == 0 {
            return "剩余 \(hours) 小时"
        }
        return "剩余 \(hours) 小时 \(remainderMinutes) 分钟"
    }
}

public struct UnattendedAuthHistoryStore: Sendable {
    public let url: URL?
    public static let maxSessions = 30

    public init(url: URL?) {
        self.url = url
    }

    public static var standard: Self {
        Self(url: URL.applicationSupportDirectory.appending(path: "Vorsmate/unattended-auth-history.json"))
    }

    public static var inMemory: Self {
        Self(url: nil)
    }

    public func load() -> [UnattendedAuthSessionRecord] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
            let records = try? decoder.decode([UnattendedAuthSessionRecord].self, from: data)
        else { return [] }
        return Array(records.prefix(Self.maxSessions))
    }

    public func save(_ records: [UnattendedAuthSessionRecord]) throws {
        guard let url else { return }
        let trimmed = Array(records.prefix(Self.maxSessions))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(trimmed)
        try withConfigurationWriteLock(at: url) {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
