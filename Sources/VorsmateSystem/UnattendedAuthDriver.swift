// [INPUT]: Security 钥匙串、OpenDirectory 本地口令核验、ApplicationServices 辅助功能与系统锁屏/唤醒通知。
// [OUTPUT]: 密码存储与校验、开启时补查、事件驱动授权弹窗监测与纯内存预览驱动。
// [POS]: VorsmateSystem 系统适配层；不向日志或剪贴板写入密码，受阻时明确返回未处理结果。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenDirectory
import Security
import VorsmateCore

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

public struct DetectedAuthDialog: Equatable, Sendable {
    public let id: String
    public let source: String
    public let summary: String
    public let isTouchIDOnly: Bool
    public let hasPasswordField: Bool
    public let manualConfirmationReason: String?

    public init(
        id: String,
        source: String,
        summary: String,
        isTouchIDOnly: Bool = false,
        hasPasswordField: Bool = true,
        manualConfirmationReason: String? = nil
    ) {
        self.id = id
        self.source = source
        self.summary = summary
        self.isTouchIDOnly = isTouchIDOnly
        self.hasPasswordField = hasPasswordField
        self.manualConfirmationReason = manualConfirmationReason
    }
}

public enum AuthDialogApprovalResult: Equatable, Sendable {
    case approved(detail: String?)
    case blocked(reason: String)
    case leftForUser(reason: String)
    case passwordRejected(reason: String)
}

@MainActor
public protocol UnattendedAuthSystemDriver: AnyObject {
    var isPreview: Bool { get }
    func isAccessibilityTrusted() -> Bool
    func requestAccessibilityTrust()
    func openAccessibilitySettings()
    func isScreenCurrentlyLocked() -> Bool
    func startMonitoring(
        onDialog: @escaping @MainActor (DetectedAuthDialog) -> Void,
        onScreenLockChanged: @escaping @MainActor (Bool) -> Void,
        onWake: @escaping @MainActor () -> Void
    ) throws
    func checkExistingDialogs()
    func stopMonitoring()
    func approveDialog(id: String, password: String) async -> AuthDialogApprovalResult
    func approveDialog(id: String, password: String, deadline: Date?) async -> AuthDialogApprovalResult
}

extension UnattendedAuthSystemDriver {
    public func approveDialog(id: String, password: String, deadline: Date?) async -> AuthDialogApprovalResult {
        await approveDialog(id: id, password: password)
    }
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
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
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

@MainActor
public final class PreviewUnattendedAuthDriver: UnattendedAuthSystemDriver {
    public let isPreview = true
    public var trusted = true
    public var locked = false
    private var onDialog: (@MainActor (DetectedAuthDialog) -> Void)?
    private var onScreenLockChanged: (@MainActor (Bool) -> Void)?
    private var onWake: (@MainActor () -> Void)?

    public init(trusted: Bool = true) {
        self.trusted = trusted
    }

    public func isAccessibilityTrusted() -> Bool { trusted }
    public func requestAccessibilityTrust() { trusted = true }
    public func openAccessibilitySettings() {}
    public func isScreenCurrentlyLocked() -> Bool { locked }

    public func startMonitoring(
        onDialog: @escaping @MainActor (DetectedAuthDialog) -> Void,
        onScreenLockChanged: @escaping @MainActor (Bool) -> Void,
        onWake: @escaping @MainActor () -> Void
    ) throws {
        self.onDialog = onDialog
        self.onScreenLockChanged = onScreenLockChanged
        self.onWake = onWake
    }

    public func stopMonitoring() {
        onDialog = nil
        onScreenLockChanged = nil
        onWake = nil
    }

    public func checkExistingDialogs() {}

    public func approveDialog(id: String, password: String) async -> AuthDialogApprovalResult {
        .blocked(reason: "预览模式不向系统弹窗提交密码")
    }
}

@MainActor
public final class SystemUnattendedAuthDriver: UnattendedAuthSystemDriver {
    public let isPreview = false

    private static let authHostBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent",
        "com.apple.CoreServicesUIAgent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.CoreAuthenticationUI",
    ]
    private static let authHostNameFragments = [
        "SecurityAgent",
        "CoreServicesUIAgent",
        "coreautha",
        "CoreAuthenticationUI",
    ]
    private nonisolated static let privacyExtensionID = "com.apple.settings.PrivacySecurity.extension"
    private nonisolated static let systemSettingsID = "com.apple.systempreferences"
    private nonisolated static let embeddedAuthServiceID = "com.apple.LocalAuthenticationRemoteService"
    private static let approveButtonTitles: Set<String> = [
        "好", "允许", "允许访问", "修改设置", "更新设置", "解锁", "安装软件", "安装帮助程序", "继续", "批准",
        "OK", "Allow", "Allow Access", "Modify Settings", "Update Settings", "Unlock", "Install Software",
        "Install Helper", "Continue", "Approve",
    ]
    private static let usePasswordButtonTitles: Set<String> = [
        "使用密码…", "使用密码...", "使用密码", "Use Password…", "Use Password...", "Use Password",
    ]

    private struct TrackedDialog {
        let id: String
        let pid: pid_t
        let window: AXUIElement
        let detectedAt: Date
    }

    private struct InspectedDialog {
        let texts: [String]
        let passwordField: AXUIElement?
        let approveButton: AXUIElement?
        let usePasswordButton: AXUIElement?
    }

    public enum WindowPresence: Equatable, Sendable {
        case present
        case absent
        case unknown
    }

    private var onDialog: (@MainActor (DetectedAuthDialog) -> Void)?
    private var onScreenLockChanged: (@MainActor (Bool) -> Void)?
    private var onWake: (@MainActor () -> Void)?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var trackedDialogs: [String: TrackedDialog] = [:]
    private var recentFingerprints: [String: Date] = [:]
    private var handledWindows: [pid_t: [AXUIElement]] = [:]
    private var privacyApplicationObserver: NSKeyValueObservation?
    private var privacyScanTask: Task<Void, Never>?
    private var monitoringID: UUID?
    private var monitoring = false
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    deinit {
        // stopMonitoring() 应在主线程停用时调用；此处仅作兜底保护。
    }

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibilityTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanTrue] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func isScreenCurrentlyLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    public func startMonitoring(
        onDialog: @escaping @MainActor (DetectedAuthDialog) -> Void,
        onScreenLockChanged: @escaping @MainActor (Bool) -> Void,
        onWake: @escaping @MainActor () -> Void
    ) throws {
        stopMonitoring()
        monitoring = true
        let id = UUID()
        monitoringID = id
        self.onDialog = onDialog
        self.onScreenLockChanged = onScreenLockChanged
        self.onWake = onWake

        let wsCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
        ] {
            workspaceObservers.append(
                wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    Task { @MainActor [weak self] in
                        guard let self, self.monitoring, let app else { return }
                        self.handleApplicationEvent(app)
                    }
                })
        }
        workspaceObservers.append(
            wsCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                Task { @MainActor [weak self] in
                    guard let self, let pid else { return }
                    self.detachAXObserver(for: pid)
                }
            })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(
                wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.monitoring else { return }
                        self.onWake?()
                    }
                })
        }

        let distCenter = DistributedNotificationCenter.default()
        distributedObservers.append(
            distCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.monitoring else { return }
                    self.onScreenLockChanged?(true)
                }
            })
        distributedObservers.append(
            distCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.monitoring else { return }
                    self.onScreenLockChanged?(false)
                }
            })

        privacyApplicationObserver = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) {
            [weak self] _, change in
            let previous = Set(
                (change.oldValue ?? []).filter(Self.isPrivacyRelatedApplication).map(\.processIdentifier))
            let current = Set((change.newValue ?? []).filter(Self.isPrivacyRelatedApplication).map(\.processIdentifier))
            guard current != previous else { return }
            Task { @MainActor [weak self] in
                guard let self, self.monitoringID == id else { return }
                for pid in previous.subtracting(current) {
                    self.detachAXObserver(for: pid)
                }
                if !current.subtracting(previous).isEmpty {
                    self.attachPrivacyObservers()
                    self.checkForNewPrivacyDialog()
                }
            }
        }
    }

    public func checkExistingDialogs() {
        guard monitoring else { return }
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && isAuthHost(app) {
            attachAXObserver(for: app)
            inspectApplicationWindows(
                pid: app.processIdentifier,
                fallbackName: app.localizedName ?? "系统授权",
                manualReason: "开启前已存在的请求由本人确认")
        }
        attachPrivacyObservers()
        _ = inspectPrivacySettingsDialogs(manualReason: "开启前已存在的请求由本人确认")
    }

    public func stopMonitoring() {
        monitoring = false
        monitoringID = nil
        privacyApplicationObserver?.invalidate()
        privacyApplicationObserver = nil
        privacyScanTask?.cancel()
        privacyScanTask = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers = []
        for pid in Array(axObservers.keys) {
            detachAXObserver(for: pid)
        }
        trackedDialogs = [:]
        recentFingerprints = [:]
        handledWindows = [:]
        onDialog = nil
        onScreenLockChanged = nil
        onWake = nil
    }

    public func approveDialog(id: String, password: String) async -> AuthDialogApprovalResult {
        await approveDialog(id: id, password: password, deadline: nil)
    }

    public func approveDialog(id: String, password: String, deadline: Date?) async -> AuthDialogApprovalResult {
        guard !Task.isCancelled, monitoring, let capturedMonitoringID = monitoringID else {
            return .leftForUser(reason: "模式已关闭，未提交授权")
        }
        if let deadline, clock() >= deadline {
            return .leftForUser(reason: "已到达截止时间，未提交授权")
        }
        guard let tracked = trackedDialogs[id] else {
            return .leftForUser(reason: "授权弹窗已不存在")
        }
        defer { trackedDialogs.removeValue(forKey: id) }

        guard let hostApp = NSRunningApplication(processIdentifier: tracked.pid),
            !hostApp.isTerminated,
            isAuthHost(hostApp)
        else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "无法验证系统授权弹窗签名身份，已保留由本人确认")
        }

        switch windowPresence(tracked.window, pid: tracked.pid) {
        case .present:
            break
        case .absent:
            return .leftForUser(reason: "授权弹窗已关闭")
        case .unknown:
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "无法确认弹窗是否关闭，已保留由本人确认")
        }

        var inspected = inspectWindow(tracked.window)
        if inspected.passwordField == nil, let usePasswordButton = inspected.usePasswordButton {
            let pressErr = AXUIElementPerformAction(usePasswordButton, kAXPressAction as CFString)
            if pressErr == .success {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, monitoring, monitoringID == capturedMonitoringID else {
                    return .leftForUser(reason: "模式已关闭，未提交授权")
                }
                if let deadline, clock() >= deadline {
                    return .leftForUser(reason: "已到达截止时间，未提交授权")
                }
                switch windowPresence(tracked.window, pid: tracked.pid) {
                case .present:
                    break
                case .absent:
                    return .leftForUser(reason: "授权弹窗已关闭")
                case .unknown:
                    markWindowHandled(tracked.window, pid: tracked.pid)
                    return .blocked(reason: "无法确认弹窗是否关闭，已保留由本人确认")
                }
                inspected = inspectWindow(tracked.window)
            } else {
                markWindowHandled(tracked.window, pid: tracked.pid)
                return .blocked(reason: "触控 ID 界面无法切换到密码输入，已保留由本人确认")
            }
        }

        guard let passwordField = inspected.passwordField else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .leftForUser(reason: "未识别到管理员密码输入框，已保留由本人确认")
        }

        var fieldPID: pid_t = 0
        AXUIElementGetPid(passwordField, &fieldPID)
        let inputPID = fieldPID != 0 ? fieldPID : tracked.pid
        let validInputPID: Bool
        if inputPID == tracked.pid {
            validInputPID = Self.isVerifiedAppleProcess(pid: inputPID)
        } else if let inputApp = NSRunningApplication(processIdentifier: inputPID), !inputApp.isTerminated {
            validInputPID = isAuthHost(inputApp)
        } else {
            validInputPID = false
        }
        guard validInputPID else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "无法验证密码输入框所属系统进程，已保留由本人确认")
        }

        guard !Task.isCancelled, monitoring, monitoringID == capturedMonitoringID else {
            return .leftForUser(reason: "模式已关闭，未提交授权")
        }
        if let deadline, clock() >= deadline {
            return .leftForUser(reason: "已到达截止时间，未提交授权")
        }

        var submitted = false
        let setValueErr = AXUIElementSetAttributeValue(
            passwordField, kAXValueAttribute as CFString, password as CFTypeRef)
        if setValueErr == .success {
            if let approveButton = inspected.approveButton {
                let pressErr = AXUIElementPerformAction(approveButton, kAXPressAction as CFString)
                submitted = (pressErr == .success)
            }
            if !submitted {
                submitted = submitReturnKey(to: inputPID, focus: passwordField)
            }
        } else {
            // 系统保护可能阻止 AXValue 写入；仅在前台窗口可读时尝试一次键入并立即复核结果。
            submitted = typePasswordAndReturn(password, into: passwordField, pid: inputPID)
        }

        guard submitted else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "系统限制自动输入或提交密码，已保留由本人确认")
        }

        // 有界复核：仅在明确确认弹窗已消失时才判为已批准，AX 报错或未知状态绝不假阳性报告。
        var sawUnknown = false
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, monitoring, monitoringID == capturedMonitoringID else {
                return .blocked(reason: "无法确认弹窗是否关闭，已保留由本人确认")
            }
            switch windowPresence(tracked.window, pid: tracked.pid) {
            case .absent:
                return .approved(detail: "已提交授权且弹窗已关闭")
            case .present:
                sawUnknown = false
            case .unknown:
                sawUnknown = true
            }
        }

        markWindowHandled(tracked.window, pid: tracked.pid)
        if sawUnknown {
            return .blocked(reason: "无法确认弹窗是否关闭，已保留由本人确认")
        }
        let afterTexts = inspectWindow(tracked.window).texts.joined(separator: " ")
        if Self.isPasswordRejectedText(afterTexts) {
            return .passwordRejected(reason: "系统提示密码未通过验证")
        }
        return .blocked(reason: "弹窗未关闭，已保留由本人确认")
    }

    public static func isVerifiedAppleProcess(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else {
            return false
        }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    public static func matchesAuthHost(bundleIdentifier: String?, processNames: [String]) -> Bool {
        if let bundleID = bundleIdentifier,
            authHostBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
        {
            return true
        }
        return processNames.contains { name in
            !name.isEmpty && authHostNameFragments.contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    public static func isPasswordRejectedText(_ text: String) -> Bool {
        text.contains("重试")
            || text.contains("无效")
            || text.contains("错误")
            || text.localizedCaseInsensitiveContains("try again")
            || text.localizedCaseInsensitiveContains("incorrect")
            || text.localizedCaseInsensitiveContains("invalid")
    }

    private nonisolated static func isPrivacyRelatedApplication(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == privacyExtensionID || app.bundleIdentifier == embeddedAuthServiceID
    }

    private func checkForNewPrivacyDialog() {
        privacyScanTask?.cancel()
        privacyScanTask = Task { @MainActor [weak self] in
            // 后台服务可能先注册，系统设置随后才显示弹层。
            for delay in [0, 250, 750, 1_000] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled, let self, self.monitoring else { return }
                if self.inspectPrivacySettingsDialogs() { return }
            }
        }
    }

    private func attachPrivacyObservers() {
        for bundleID in [Self.privacyExtensionID, Self.systemSettingsID] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isTerminated
            {
                attachAXObserver(for: app)
            }
        }
    }

    private func inspectPrivacySettingsDialogs(manualReason: String = "隐私与安全请求由本人确认") -> Bool {
        var found = false
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.privacyExtensionID)
        where !app.isTerminated && Self.isVerifiedAppleProcess(pid: app.processIdentifier) {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            // 系统设置拥有窗口，隐私与安全扩展的焦点窗口指向内嵌弹层。
            guard let sheet = copyElementAttribute(appElement, kAXFocusedWindowAttribute),
                copyStringAttribute(sheet, kAXRoleAttribute) == kAXSheetRole
            else { continue }
            let inspected = inspectWindow(sheet)
            guard inspected.passwordField != nil || inspected.usePasswordButton != nil,
                !inspected.texts.isEmpty
            else { continue }
            found = true
            report(
                window: sheet, pid: pid, fallbackName: "隐私与安全", inspected: inspected,
                manualReason: manualReason)
        }
        if !found {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.systemSettingsID)
            where !app.isTerminated && Self.isVerifiedAppleProcess(pid: app.processIdentifier) {
                let pid = app.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                for sheet in collectSheets(of: appElement) {
                    let inspected = inspectWindow(sheet)
                    guard inspected.passwordField != nil || inspected.usePasswordButton != nil,
                        !inspected.texts.isEmpty
                    else { continue }
                    found = true
                    report(
                        window: sheet, pid: pid, fallbackName: "隐私与安全", inspected: inspected,
                        manualReason: manualReason)
                }
            }
        }
        return found
    }

    private func handleApplicationEvent(_ app: NSRunningApplication) {
        if isAuthHost(app) {
            attachAXObserver(for: app)
            inspectApplicationWindows(pid: app.processIdentifier, fallbackName: app.localizedName ?? "系统授权")
            return
        }
        if (Self.isPrivacyRelatedApplication(app) || app.bundleIdentifier == Self.systemSettingsID)
            && Self.isVerifiedAppleProcess(pid: app.processIdentifier)
        {
            attachAXObserver(for: app)
            checkForNewPrivacyDialog()
        }
    }

    private func isAuthHost(_ app: NSRunningApplication) -> Bool {
        let names = [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 }
        guard Self.matchesAuthHost(bundleIdentifier: app.bundleIdentifier, processNames: names) else {
            return false
        }
        return Self.isVerifiedAppleProcess(pid: app.processIdentifier)
    }

    private func attachAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard axObservers[pid] == nil, isAccessibilityTrusted() else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let driver = Unmanaged<SystemUnattendedAuthDriver>.fromOpaque(refcon).takeUnretainedValue()
            let notifName = notification as String
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            Task { @MainActor [weak driver] in
                driver?.handleAXNotification(name: notifName, element: element, pid: pid)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXSheetCreatedNotification,
        ]
        var addedAny = false
        for name in notifications {
            if AXObserverAddNotification(observer, appElement, name as CFString, refcon) == .success {
                addedAny = true
            }
        }
        guard addedAny else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer
    }

    private func detachAXObserver(for pid: pid_t) {
        handledWindows.removeValue(forKey: pid)
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func handleAXNotification(name: String, element: AXUIElement, pid: pid_t) {
        guard monitoring else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.bundleIdentifier == Self.privacyExtensionID || app?.bundleIdentifier == Self.systemSettingsID {
            guard Self.isVerifiedAppleProcess(pid: pid) else { return }
            let role = copyStringAttribute(element, kAXRoleAttribute)
            if role == kAXSheetRole {
                let inspected = inspectWindow(element)
                if inspected.passwordField != nil || inspected.usePasswordButton != nil {
                    report(
                        window: element, pid: pid, fallbackName: "隐私与安全", inspected: inspected,
                        manualReason: "隐私与安全请求由本人确认")
                }
            } else {
                _ = inspectPrivacySettingsDialogs(manualReason: "隐私与安全请求由本人确认")
            }
            return
        }
        guard let app, !app.isTerminated, isAuthHost(app) else { return }
        let fallback = app.localizedName ?? "系统授权"
        report(window: element, pid: pid, fallbackName: fallback, inspected: inspectWindow(element))
    }

    private func inspectApplicationWindows(pid: pid_t, fallbackName: String, manualReason: String? = nil) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        var windows = value as? [AXUIElement] ?? []
        if let focused = copyElementAttribute(appElement, kAXFocusedWindowAttribute),
            !windows.contains(where: { CFEqual($0, focused) })
        {
            windows.append(focused)
        }
        for window in windows {
            report(
                window: window, pid: pid, fallbackName: fallbackName, inspected: inspectWindow(window),
                manualReason: manualReason)
        }
    }

    private func markWindowHandled(_ window: AXUIElement, pid: pid_t) {
        var list = handledWindows[pid] ?? []
        if !list.contains(where: { CFEqual($0, window) }) {
            list.append(window)
            handledWindows[pid] = list
        }
    }

    private func report(
        window: AXUIElement, pid: pid_t, fallbackName: String, inspected: InspectedDialog, manualReason: String? = nil
    ) {
        if let existing = handledWindows[pid] {
            let alive = existing.filter { windowPresence($0, pid: pid) != .absent }
            handledWindows[pid] = alive.isEmpty ? nil : alive
            if alive.contains(where: { CFEqual($0, window) }) { return }
        }
        if trackedDialogs.values.contains(where: { $0.pid == pid && CFEqual($0.window, window) }) { return }
        let hasPassword = inspected.passwordField != nil
        let isTouchIDOnly = !hasPassword && inspected.usePasswordButton != nil
        if manualReason != nil && !hasPassword && !isTouchIDOnly { return }
        guard hasPassword || isTouchIDOnly || !inspected.texts.isEmpty else { return }
        guard hasPassword || isTouchIDOnly || inspected.approveButton != nil else { return }

        let joinedText = inspected.texts.joined(separator: " ")
        let summary = UnattendedAuthSanitizer.sanitizeText(
            joinedText.isEmpty ? "\(fallbackName) 管理员授权请求" : joinedText)
        let source = UnattendedAuthSanitizer.extractRequester(from: summary, fallback: fallbackName)

        let dialogID = UUID().uuidString
        if manualReason != nil {
            markWindowHandled(window, pid: pid)
        } else {
            let now = Date()
            recentFingerprints = recentFingerprints.filter { now.timeIntervalSince($0.value) < 6 }
            let fingerprint = "\(pid)::\(summary)"
            if recentFingerprints[fingerprint] != nil { return }
            recentFingerprints[fingerprint] = now
            trackedDialogs[dialogID] = TrackedDialog(id: dialogID, pid: pid, window: window, detectedAt: now)
        }
        let detected = DetectedAuthDialog(
            id: dialogID,
            source: source,
            summary: summary,
            isTouchIDOnly: isTouchIDOnly,
            hasPasswordField: hasPassword,
            manualConfirmationReason: manualReason
        )
        onDialog?(detected)
    }

    private func inspectWindow(_ window: AXUIElement) -> InspectedDialog {
        var texts: [String] = []
        var passwordField: AXUIElement?
        var approveButton: AXUIElement? = copyElementAttribute(window, kAXDefaultButtonAttribute)
        var usePasswordButton: AXUIElement?

        if let title = copyStringAttribute(window, kAXTitleAttribute), !title.isEmpty {
            texts.append(title)
        }

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 200 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            let role = copyStringAttribute(node, kAXRoleAttribute) ?? ""
            let subrole = copyStringAttribute(node, kAXSubroleAttribute) ?? ""

            if role == kAXStaticTextRole {
                if let value = copyStringAttribute(node, kAXValueAttribute), !value.isEmpty {
                    texts.append(value)
                } else if let title = copyStringAttribute(node, kAXTitleAttribute), !title.isEmpty {
                    texts.append(title)
                }
            } else if role == kAXTextFieldRole && subrole == kAXSecureTextFieldSubrole {
                // 绝不读取密码框内容，只记录控件引用。
                if passwordField == nil { passwordField = node }
            } else if role == kAXButtonRole {
                let title = copyStringAttribute(node, kAXTitleAttribute) ?? ""
                if usePasswordButton == nil && Self.usePasswordButtonTitles.contains(title) {
                    usePasswordButton = node
                } else if approveButton == nil && Self.approveButtonTitles.contains(title) {
                    approveButton = node
                }
            }

            guard depth < 8 else { continue }
            for child in copyChildren(node) {
                queue.append((child, depth + 1))
            }
        }

        return InspectedDialog(
            texts: deduplicatePreservingOrder(texts),
            passwordField: passwordField,
            approveButton: approveButton,
            usePasswordButton: usePasswordButton
        )
    }

    public static func classifyWindowPresence(
        processTerminated: Bool,
        windowsError: AXError,
        matchesWindowsOrSheets: Bool,
        focusedError: AXError,
        matchesFocused: Bool,
        mainError: AXError,
        matchesMain: Bool
    ) -> WindowPresence {
        if processTerminated {
            return .absent
        }
        if matchesWindowsOrSheets || matchesFocused || matchesMain {
            return .present
        }
        let nonFatalErrors: Set<AXError> = [.success, .noValue, .attributeUnsupported]
        if !nonFatalErrors.contains(windowsError)
            || !nonFatalErrors.contains(focusedError)
            || !nonFatalErrors.contains(mainError)
        {
            return .unknown
        }
        return .absent
    }

    private func windowPresence(_ target: AXUIElement, pid: pid_t) -> WindowPresence {
        if NSRunningApplication(processIdentifier: pid)?.isTerminated == true {
            return .absent
        }
        if kill(pid, 0) != 0 && errno == ESRCH {
            return .absent
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let windowsErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        var matchesWindowsOrSheets = false
        if windowsErr == .success, let windows = windowsValue as? [AXUIElement] {
            if windows.contains(where: { CFEqual($0, target) }) {
                matchesWindowsOrSheets = true
            } else {
                for window in windows where copySheets(window).contains(where: { CFEqual($0, target) }) {
                    matchesWindowsOrSheets = true
                    break
                }
            }
        }

        var focusedValue: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue)
        let matchesFocused =
            focusedErr == .success
            && focusedValue.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, target) } == true

        var mainValue: CFTypeRef?
        let mainErr = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainValue)
        let matchesMain =
            mainErr == .success
            && mainValue.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, target) } == true

        return Self.classifyWindowPresence(
            processTerminated: false,
            windowsError: windowsErr,
            matchesWindowsOrSheets: matchesWindowsOrSheets,
            focusedError: focusedErr,
            matchesFocused: matchesFocused,
            mainError: mainErr,
            matchesMain: matchesMain)
    }

    private func collectSheets(of appElement: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        {
            for window in windows {
                for sheet in copySheets(window) where !result.contains(where: { CFEqual($0, sheet) }) {
                    result.append(sheet)
                }
            }
        }
        if let focused = copyElementAttribute(appElement, kAXFocusedWindowAttribute),
            copyStringAttribute(focused, kAXRoleAttribute) == kAXSheetRole,
            !result.contains(where: { CFEqual($0, focused) })
        {
            result.append(focused)
        }
        return result
    }

    private func copySheets(_ window: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &value) == .success,
            let sheets = value as? [AXUIElement]
        {
            result.append(contentsOf: sheets)
        }
        for child in copyChildren(window) where copyStringAttribute(child, kAXRoleAttribute) == kAXSheetRole {
            if !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }
        return result
    }

    private func typePasswordAndReturn(_ password: String, into field: AXUIElement, pid: pid_t) -> Bool {
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let utf16 = Array(password.utf16)
        for codeUnit in utf16 {
            var unit = codeUnit
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return submitReturnKey(to: pid, focus: field)
    }

    private func submitReturnKey(to pid: pid_t, focus: AXUIElement) -> Bool {
        _ = AXUIElementSetAttributeValue(focus, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else { return false }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let children = value as? [AXUIElement]
        else { return [] }
        return children
    }

    private func deduplicatePreservingOrder(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
