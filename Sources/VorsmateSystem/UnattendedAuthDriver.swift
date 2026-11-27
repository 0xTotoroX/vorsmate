// [INPUT]: UnattendedAuthAX 辅助功能 / 验签工具、NSWorkspace 与锁屏/唤醒通知。
// [OUTPUT]: 授权弹窗模型、驱动协议、事件驱动系统监听/批准实现与纯内存预览驱动。
// [POS]: VorsmateSystem 无人值守授权驱动核心；已有弹窗和「隐私与安全」内嵌请求仅记录由本人确认，受阻绝不伪装已批准。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VorsmateCore

public struct DetectedAuthDialog: Equatable, Sendable {
    public let id: String
    public let source: String
    public let summary: String
    public let category: UnattendedAuthDialogCategory
    public let isExisting: Bool
    public let isTouchIDOnly: Bool
    public let hasPasswordField: Bool
    public let manualConfirmationReason: String?

    public init(
        id: String,
        source: String,
        summary: String,
        category: UnattendedAuthDialogCategory = .systemAdmin,
        isExisting: Bool = false,
        isTouchIDOnly: Bool = false,
        hasPasswordField: Bool = true,
        manualConfirmationReason: String? = nil
    ) {
        self.id = id
        self.source = source
        self.summary = summary
        self.category = category
        self.isExisting = isExisting
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
    func releaseDialog(id: String)
    func approveDialog(id: String, password: String) async -> AuthDialogApprovalResult
    func approveDialog(id: String, password: String, deadline: Date?) async -> AuthDialogApprovalResult
}

extension UnattendedAuthSystemDriver {
    public func releaseDialog(id: String) {}

    public func approveDialog(id: String, password: String, deadline: Date?) async -> AuthDialogApprovalResult {
        await approveDialog(id: id, password: password)
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
    private nonisolated static let embeddedAuthServiceBundleIDs: Set<String> = [
        "com.apple.LocalAuthenticationRemoteService",
        "com.apple.AuthenticationServices.Helper",
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
        "com.apple.AuthKitUI.AKAuthorizationRemoteViewService",
    ]
    private nonisolated static let embeddedAuthServiceNameFragments = [
        "LocalAuthenticationRemoteService",
        "AuthenticationServicesHelper",
        "AuthenticationServicesAgent",
        "AKAuthorizationRemoteViewService",
    ]
    private nonisolated static let privacyExtensionID = "com.apple.settings.PrivacySecurity.extension"
    private nonisolated static let systemSettingsID = "com.apple.systempreferences"

    private struct TrackedDialog {
        let id: String
        let pid: pid_t
        let window: AXUIElement
        let category: UnattendedAuthDialogCategory
        let fallbackPasswordField: AXUIElement?
        let detectedAt: Date
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
    private var embeddedAuthApplicationObserver: NSKeyValueObservation?
    private var embeddedAuthScanTask: Task<Void, Never>?
    private var monitoringID: UUID?
    private var monitoring = false
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
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

        registerWorkspaceObservers()
        registerScreenLockObservers()
        registerEmbeddedAuthObserver(monitoringID: id)
        attachEmbeddedAuthObservers()
    }

    public func checkExistingDialogs() {
        guard monitoring else { return }
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && isAuthHost(app) {
            attachAXObserver(for: app)
            inspectApplicationWindows(
                pid: app.processIdentifier,
                fallbackName: app.localizedName ?? "系统授权",
                category: .systemAdmin,
                isExisting: true)
        }
        attachEmbeddedAuthObservers()
        _ = inspectEmbeddedAuthDialogs(isExisting: true)
    }

    public func stopMonitoring() {
        monitoring = false
        monitoringID = nil
        embeddedAuthApplicationObserver?.invalidate()
        embeddedAuthApplicationObserver = nil
        embeddedAuthScanTask?.cancel()
        embeddedAuthScanTask = nil
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

    public func releaseDialog(id: String) {
        guard let tracked = trackedDialogs.removeValue(forKey: id) else { return }
        markWindowHandled(tracked.window, pid: tracked.pid)
    }

    public func approveDialog(id: String, password: String) async -> AuthDialogApprovalResult {
        await approveDialog(id: id, password: password, deadline: nil)
    }

    public func approveDialog(id: String, password: String, deadline: Date?) async -> AuthDialogApprovalResult {
        guard let capturedMonitoringID = monitoringID else {
            return .leftForUser(reason: "模式已关闭，未提交授权")
        }
        if let stopped = checkSubmissionAllowed(monitoringID: capturedMonitoringID, deadline: deadline) {
            return stopped
        }
        guard let tracked = trackedDialogs[id] else {
            return .leftForUser(reason: "授权弹窗已不存在")
        }
        defer { trackedDialogs.removeValue(forKey: id) }

        guard let hostApp = NSRunningApplication(processIdentifier: tracked.pid),
            !hostApp.isTerminated,
            isValidDialogHost(hostApp, category: tracked.category)
        else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "无法验证系统授权弹窗签名身份，已保留由本人确认")
        }

        if let unavailable = checkWindowPresentOrStop(tracked) { return unavailable }

        var inspected = UnattendedAuthAX.inspectWindow(
            tracked.window, fallbackPasswordField: tracked.fallbackPasswordField)
        if inspected.passwordField == nil, let usePasswordButton = inspected.usePasswordButton {
            guard
                verifiedControlPID(for: usePasswordButton, category: tracked.category, fallbackHostPID: tracked.pid)
                    != nil
            else {
                markWindowHandled(tracked.window, pid: tracked.pid)
                return .blocked(reason: "无法验证密码切换按钮所属系统进程，已保留由本人确认")
            }
            guard AXUIElementPerformAction(usePasswordButton, kAXPressAction as CFString) == .success else {
                markWindowHandled(tracked.window, pid: tracked.pid)
                return .blocked(reason: "触控 ID 界面无法切换到密码输入，已保留由本人确认")
            }
            try? await Task.sleep(for: .milliseconds(350))
            if let stopped = checkSubmissionAllowed(monitoringID: capturedMonitoringID, deadline: deadline) {
                return stopped
            }
            if let unavailable = checkWindowPresentOrStop(tracked) { return unavailable }
            inspected = UnattendedAuthAX.inspectWindow(
                tracked.window, fallbackPasswordField: tracked.fallbackPasswordField)
        }

        guard let passwordField = inspected.passwordField else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .leftForUser(reason: "未识别到管理员密码输入框，已保留由本人确认")
        }

        guard
            let inputPID = verifiedControlPID(
                for: passwordField, category: tracked.category, fallbackHostPID: tracked.pid)
        else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "无法验证密码输入框所属系统进程，已保留由本人确认")
        }

        if let stopped = checkSubmissionAllowed(monitoringID: capturedMonitoringID, deadline: deadline) {
            return stopped
        }

        guard submitPassword(password, into: passwordField, approveButton: inspected.approveButton, pid: inputPID)
        else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "系统限制自动输入或提交密码，已保留由本人确认")
        }

        return await verifyDialogDismissed(tracked, monitoringID: capturedMonitoringID)
    }

    public static func isVerifiedAppleProcess(pid: pid_t) -> Bool {
        UnattendedAuthAX.isVerifiedAppleProcess(pid: pid)
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

    public static func matchesEmbeddedAuthService(bundleIdentifier: String?, processNames: [String]) -> Bool {
        if let bundleID = bundleIdentifier,
            embeddedAuthServiceBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
        {
            return true
        }
        return processNames.contains { name in
            !name.isEmpty && embeddedAuthServiceNameFragments.contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    public static func matchesPrivacyAuthHost(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier.caseInsensitiveCompare(privacyExtensionID) == .orderedSame
            || bundleIdentifier.caseInsensitiveCompare(systemSettingsID) == .orderedSame
    }

    public static func isPasswordRejectedText(_ text: String) -> Bool {
        text.contains("重试")
            || text.contains("无效")
            || text.contains("错误")
            || text.localizedCaseInsensitiveContains("try again")
            || text.localizedCaseInsensitiveContains("incorrect")
            || text.localizedCaseInsensitiveContains("invalid")
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
        if processTerminated { return .absent }
        if matchesWindowsOrSheets || matchesFocused || matchesMain { return .present }
        let nonFatalErrors: Set<AXError> = [.success, .noValue, .attributeUnsupported]
        if !nonFatalErrors.contains(windowsError)
            || !nonFatalErrors.contains(focusedError)
            || !nonFatalErrors.contains(mainError)
        {
            return .unknown
        }
        return .absent
    }

    private func registerWorkspaceObservers() {
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
    }

    private func registerScreenLockObservers() {
        let distCenter = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(
                distCenter.addObserver(
                    forName: NSNotification.Name(name), object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.monitoring else { return }
                        self.onScreenLockChanged?(locked)
                    }
                })
        }
    }

    private func registerEmbeddedAuthObserver(monitoringID id: UUID) {
        embeddedAuthApplicationObserver = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) {
            [weak self] _, change in
            let previous = Set(
                (change.oldValue ?? []).filter(Self.isObservedEmbeddedProcess).map(\.processIdentifier))
            let current = Set(
                (change.newValue ?? []).filter(Self.isObservedEmbeddedProcess).map(\.processIdentifier))
            guard current != previous else { return }
            Task { @MainActor [weak self] in
                guard let self, self.monitoringID == id else { return }
                for pid in previous.subtracting(current) {
                    self.detachAXObserver(for: pid)
                }
                if !current.subtracting(previous).isEmpty {
                    self.attachEmbeddedAuthObservers()
                    self.scheduleEmbeddedAuthScan()
                }
            }
        }
    }

    private func checkSubmissionAllowed(monitoringID expectedID: UUID, deadline: Date?) -> AuthDialogApprovalResult? {
        guard !Task.isCancelled, monitoring, monitoringID == expectedID else {
            return .leftForUser(reason: "模式已关闭，未提交授权")
        }
        if let deadline, clock() >= deadline {
            return .leftForUser(reason: "已到达截止时间，未提交授权")
        }
        return nil
    }

    private func checkWindowPresentOrStop(_ tracked: TrackedDialog) -> AuthDialogApprovalResult? {
        switch UnattendedAuthAX.windowPresence(tracked.window, pid: tracked.pid) {
        case .present:
            return nil
        case .absent:
            return .leftForUser(reason: "授权弹窗已关闭")
        case .unknown:
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "无法确认弹窗是否关闭，已保留由本人确认")
        }
    }

    private func isValidDialogHost(_ app: NSRunningApplication, category: UnattendedAuthDialogCategory) -> Bool {
        switch category {
        case .systemAdmin:
            return isAuthHost(app)
        case .privacySettings:
            return
                (Self.matchesPrivacyAuthHost(bundleIdentifier: app.bundleIdentifier) || isEmbeddedAuthService(app)
                || isAuthHost(app))
                && Self.isVerifiedAppleProcess(pid: app.processIdentifier)
        case .credentialAndAppAuth:
            // 通行密钥 / 应用内验证弹层可能挂载在普通宿主应用窗口上，控制元素自身会再做 Apple 签名校验。
            return true
        }
    }

    private func verifiedControlPID(
        for element: AXUIElement,
        category: UnattendedAuthDialogCategory,
        fallbackHostPID: pid_t
    ) -> pid_t? {
        let rawPID = UnattendedAuthAX.pid(of: element)
        let controlPID = rawPID != 0 ? rawPID : fallbackHostPID
        guard Self.isVerifiedAppleProcess(pid: controlPID),
            let controlApp = NSRunningApplication(processIdentifier: controlPID),
            !controlApp.isTerminated
        else { return nil }
        switch category {
        case .systemAdmin:
            return isAuthHost(controlApp) ? controlPID : nil
        case .privacySettings:
            return
                (Self.matchesPrivacyAuthHost(bundleIdentifier: controlApp.bundleIdentifier)
                || isEmbeddedAuthService(controlApp)
                || isAuthHost(controlApp)) ? controlPID : nil
        case .credentialAndAppAuth:
            return (isEmbeddedAuthService(controlApp) || isAuthHost(controlApp)) ? controlPID : nil
        }
    }

    private func submitPassword(
        _ password: String, into passwordField: AXUIElement, approveButton: AXUIElement?, pid inputPID: pid_t
    ) -> Bool {
        let setValueErr = AXUIElementSetAttributeValue(
            passwordField, kAXValueAttribute as CFString, password as CFTypeRef)
        if setValueErr == .success {
            if let approveButton,
                AXUIElementPerformAction(approveButton, kAXPressAction as CFString) == .success
            {
                return true
            }
            return UnattendedAuthAX.submitReturnKey(to: inputPID, focus: passwordField)
        }
        // 系统保护可能阻止 AXValue 写入；仅在前台窗口可读时尝试一次键入并立即复核结果。
        return UnattendedAuthAX.typePasswordAndReturn(password, into: passwordField, pid: inputPID)
    }

    private func verifyDialogDismissed(_ tracked: TrackedDialog, monitoringID expectedID: UUID) async
        -> AuthDialogApprovalResult
    {
        // 有界复核：仅在明确确认弹窗已消失时才判为已批准，AX 报错或未知状态绝不假阳性报告。
        var sawUnknown = false
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, monitoring, monitoringID == expectedID else {
                return .blocked(reason: "无法确认弹窗是否关闭，已保留由本人确认")
            }
            switch UnattendedAuthAX.windowPresence(tracked.window, pid: tracked.pid) {
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
        let afterTexts = UnattendedAuthAX.inspectWindow(
            tracked.window, fallbackPasswordField: tracked.fallbackPasswordField
        ).texts.joined(separator: " ")
        if Self.isPasswordRejectedText(afterTexts) {
            return .passwordRejected(reason: "系统提示密码未通过验证")
        }
        return .blocked(reason: "弹窗未关闭，已保留由本人确认")
    }

    private nonisolated static func isObservedEmbeddedProcess(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier {
            if bundleID.caseInsensitiveCompare(privacyExtensionID) == .orderedSame { return true }
            if embeddedAuthServiceBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                return true
            }
        }
        let names = [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 }
        return names.contains { name in
            !name.isEmpty && embeddedAuthServiceNameFragments.contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    private func hasRunningEmbeddedAuthService() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            !app.isTerminated && isEmbeddedAuthService(app)
        }
    }

    private func scheduleEmbeddedAuthScan() {
        embeddedAuthScanTask?.cancel()
        embeddedAuthScanTask = Task { @MainActor [weak self] in
            // 后台服务可能先注册，界面弹层与远程密码框随后才挂入窗口树。
            for delay in [0, 150, 450, 900, 1_500] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled, let self, self.monitoring else { return }
                if self.inspectEmbeddedAuthDialogs(isExisting: false) { return }
            }
        }
    }

    private func attachEmbeddedAuthObservers() {
        let bundleIDs = Array(Self.embeddedAuthServiceBundleIDs) + [Self.privacyExtensionID, Self.systemSettingsID]
        for bundleID in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isTerminated
            {
                attachAXObserver(for: app)
            }
        }
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && isEmbeddedAuthService(app) {
            attachAXObserver(for: app)
        }
    }

    private func inspectEmbeddedAuthDialogs(isExisting: Bool) -> Bool {
        var found = false
        if inspectPrivacySettingsDialogs(isExisting: isExisting) {
            found = true
        }
        if inspectRunningEmbeddedAuthServices(isExisting: isExisting) {
            found = true
        }
        if hasRunningEmbeddedAuthService() {
            if inspectFocusedEmbeddedPasswordField(isExisting: isExisting) {
                found = true
            }
            if inspectFrontmostEmbeddedSheets(isExisting: isExisting) {
                found = true
            }
        }
        return found
    }

    private func inspectPrivacySettingsDialogs(isExisting: Bool) -> Bool {
        var found = false
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.privacyExtensionID)
        where !app.isTerminated && Self.isVerifiedAppleProcess(pid: app.processIdentifier) {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            // 系统设置拥有窗口，隐私与安全扩展的焦点窗口指向内嵌弹层。
            guard let sheet = UnattendedAuthAX.copyElementAttribute(appElement, kAXFocusedWindowAttribute),
                UnattendedAuthAX.copyStringAttribute(sheet, kAXRoleAttribute) == kAXSheetRole
            else { continue }
            let inspected = UnattendedAuthAX.inspectWindow(sheet)
            guard inspected.passwordField != nil || inspected.usePasswordButton != nil, !inspected.texts.isEmpty else {
                continue
            }
            found = true
            report(
                window: sheet, pid: pid, fallbackName: "隐私与安全", category: .privacySettings,
                isExisting: isExisting, inspected: inspected)
        }
        if !found {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.systemSettingsID)
            where !app.isTerminated && Self.isVerifiedAppleProcess(pid: app.processIdentifier) {
                let pid = app.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                for sheet in UnattendedAuthAX.collectSheets(of: appElement) {
                    let inspected = UnattendedAuthAX.inspectWindow(sheet)
                    guard inspected.passwordField != nil || inspected.usePasswordButton != nil,
                        !inspected.texts.isEmpty
                    else { continue }
                    found = true
                    report(
                        window: sheet, pid: pid, fallbackName: "隐私与安全", category: .privacySettings,
                        isExisting: isExisting, inspected: inspected)
                }
            }
        }
        return found
    }

    private func inspectRunningEmbeddedAuthServices(isExisting: Bool) -> Bool {
        var found = false
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && isEmbeddedAuthService(app) {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            var candidates: [AXUIElement] = []
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                let windows = value as? [AXUIElement]
            {
                candidates.append(contentsOf: windows)
            }
            if let focused = UnattendedAuthAX.copyElementAttribute(appElement, kAXFocusedWindowAttribute),
                !candidates.contains(where: { CFEqual($0, focused) })
            {
                candidates.append(focused)
            }
            for sheet in UnattendedAuthAX.collectSheets(of: appElement)
            where !candidates.contains(where: { CFEqual($0, sheet) }) {
                candidates.append(sheet)
            }
            for window in candidates {
                let inspected = UnattendedAuthAX.inspectWindow(window)
                guard inspected.passwordField != nil || inspected.usePasswordButton != nil else { continue }
                found = true
                report(
                    window: window, pid: pid, fallbackName: "密码与通行密钥", category: .credentialAndAppAuth,
                    isExisting: isExisting, inspected: inspected)
            }
        }
        return found
    }

    private func inspectFocusedEmbeddedPasswordField(isExisting: Bool) -> Bool {
        guard let focused = UnattendedAuthAX.focusedUIElement() else { return false }
        let focusedPID = UnattendedAuthAX.pid(of: focused)
        guard let focusedApp = NSRunningApplication(processIdentifier: focusedPID),
            !focusedApp.isTerminated,
            isEmbeddedAuthService(focusedApp) || isAuthHost(focusedApp)
        else { return false }

        let fallbackField = UnattendedAuthAX.isSecureTextField(focused) ? focused : nil
        let frontmost = NSWorkspace.shared.frontmostApplication
        let fallbackName = frontmost?.localizedName ?? "密码与通行密钥"

        let enclosing = UnattendedAuthAX.enclosingWindowOrSheet(for: focused)
        if let container = enclosing {
            let containerPID = UnattendedAuthAX.pid(of: container)
            let containerRole = UnattendedAuthAX.copyStringAttribute(container, kAXRoleAttribute)
            let containerIsAuth =
                NSRunningApplication(processIdentifier: containerPID).map {
                    isEmbeddedAuthService($0) || isAuthHost($0)
                } ?? false
            if containerIsAuth || containerRole == kAXSheetRole {
                let inspected = UnattendedAuthAX.inspectWindow(container, fallbackPasswordField: fallbackField)
                if hasTrustedEmbeddedControl(inspected, category: .credentialAndAppAuth, fallbackPID: focusedPID) {
                    report(
                        window: container, pid: containerPID, fallbackName: fallbackName,
                        category: .credentialAndAppAuth, isExisting: isExisting, inspected: inspected,
                        fallbackPasswordField: fallbackField)
                    return true
                }
            } else {
                // 若容器是普通宿主应用主窗口，优先取其最内层 AXSheet。
                let sheets = UnattendedAuthAX.copySheets(container)
                for sheet in sheets.reversed() {
                    let sheetPID = UnattendedAuthAX.pid(of: sheet)
                    let inspected = UnattendedAuthAX.inspectWindow(sheet, fallbackPasswordField: fallbackField)
                    if hasTrustedEmbeddedControl(inspected, category: .credentialAndAppAuth, fallbackPID: focusedPID) {
                        report(
                            window: sheet, pid: sheetPID, fallbackName: fallbackName,
                            category: .credentialAndAppAuth, isExisting: isExisting, inspected: inspected,
                            fallbackPasswordField: fallbackField)
                        return true
                    }
                }
            }
        }

        // 回退到焦点应用自身的窗口，或前台应用的最内层弹层。
        let focusedAppElement = AXUIElementCreateApplication(focusedPID)
        if let appWindow = UnattendedAuthAX.copyElementAttribute(focusedAppElement, kAXFocusedWindowAttribute) {
            let inspected = UnattendedAuthAX.inspectWindow(appWindow, fallbackPasswordField: fallbackField)
            if hasTrustedEmbeddedControl(inspected, category: .credentialAndAppAuth, fallbackPID: focusedPID) {
                report(
                    window: appWindow, pid: focusedPID, fallbackName: fallbackName,
                    category: .credentialAndAppAuth, isExisting: isExisting, inspected: inspected,
                    fallbackPasswordField: fallbackField)
                return true
            }
        }
        if let frontmost, !frontmost.isTerminated {
            let sheets = UnattendedAuthAX.collectSheets(of: AXUIElementCreateApplication(frontmost.processIdentifier))
            for sheet in sheets.reversed() {
                let sheetPID = UnattendedAuthAX.pid(of: sheet)
                let inspected = UnattendedAuthAX.inspectWindow(sheet, fallbackPasswordField: fallbackField)
                if hasTrustedEmbeddedControl(inspected, category: .credentialAndAppAuth, fallbackPID: focusedPID) {
                    report(
                        window: sheet, pid: sheetPID, fallbackName: fallbackName,
                        category: .credentialAndAppAuth, isExisting: isExisting, inspected: inspected,
                        fallbackPasswordField: fallbackField)
                    return true
                }
            }
        }
        return false
    }

    private func inspectFrontmostEmbeddedSheets(isExisting: Bool) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
            !frontmost.isTerminated,
            !isAuthHost(frontmost),
            !Self.matchesPrivacyAuthHost(bundleIdentifier: frontmost.bundleIdentifier)
        else { return false }

        let pid = frontmost.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var candidates = UnattendedAuthAX.collectSheets(of: appElement)
        if let focused = UnattendedAuthAX.copyElementAttribute(appElement, kAXFocusedWindowAttribute),
            UnattendedAuthAX.copyStringAttribute(focused, kAXRoleAttribute) == kAXSheetRole,
            !candidates.contains(where: { CFEqual($0, focused) })
        {
            candidates.append(focused)
        }

        var found = false
        let fallbackName = frontmost.localizedName ?? "密码与通行密钥"
        for sheet in candidates.reversed() {
            let inspected = UnattendedAuthAX.inspectWindow(sheet)
            guard hasTrustedEmbeddedControl(inspected, category: .credentialAndAppAuth, fallbackPID: pid) else {
                continue
            }
            found = true
            report(
                window: sheet, pid: pid, fallbackName: fallbackName, category: .credentialAndAppAuth,
                isExisting: isExisting, inspected: inspected)
        }
        return found
    }

    private func hasTrustedEmbeddedControl(
        _ inspected: UnattendedAuthInspectedDialog,
        category: UnattendedAuthDialogCategory,
        fallbackPID: pid_t
    ) -> Bool {
        if let passwordField = inspected.passwordField {
            return verifiedControlPID(for: passwordField, category: category, fallbackHostPID: fallbackPID) != nil
        }
        if let usePasswordButton = inspected.usePasswordButton {
            return verifiedControlPID(for: usePasswordButton, category: category, fallbackHostPID: fallbackPID) != nil
        }
        return false
    }

    private func handleApplicationEvent(_ app: NSRunningApplication) {
        if isAuthHost(app) {
            attachAXObserver(for: app)
            inspectApplicationWindows(
                pid: app.processIdentifier,
                fallbackName: app.localizedName ?? "系统授权",
                category: .systemAdmin,
                isExisting: false)
            return
        }
        if (Self.isObservedEmbeddedProcess(app) || Self.matchesPrivacyAuthHost(bundleIdentifier: app.bundleIdentifier))
            && Self.isVerifiedAppleProcess(pid: app.processIdentifier)
        {
            attachAXObserver(for: app)
            scheduleEmbeddedAuthScan()
            return
        }
        if hasRunningEmbeddedAuthService() {
            scheduleEmbeddedAuthScan()
        }
    }

    private func isAuthHost(_ app: NSRunningApplication) -> Bool {
        let names = [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 }
        guard Self.matchesAuthHost(bundleIdentifier: app.bundleIdentifier, processNames: names) else {
            return false
        }
        return Self.isVerifiedAppleProcess(pid: app.processIdentifier)
    }

    private func isEmbeddedAuthService(_ app: NSRunningApplication) -> Bool {
        let names = [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 }
        guard Self.matchesEmbeddedAuthService(bundleIdentifier: app.bundleIdentifier, processNames: names) else {
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
            kAXFocusedUIElementChangedNotification,
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
        if Self.matchesPrivacyAuthHost(bundleIdentifier: app?.bundleIdentifier) {
            guard Self.isVerifiedAppleProcess(pid: pid) else { return }
            if UnattendedAuthAX.copyStringAttribute(element, kAXRoleAttribute) == kAXSheetRole {
                let inspected = UnattendedAuthAX.inspectWindow(element)
                if inspected.passwordField != nil || inspected.usePasswordButton != nil {
                    report(
                        window: element, pid: pid, fallbackName: "隐私与安全", category: .privacySettings,
                        isExisting: false, inspected: inspected)
                }
            } else {
                _ = inspectEmbeddedAuthDialogs(isExisting: false)
            }
            return
        }
        if let app, !app.isTerminated, isEmbeddedAuthService(app) {
            _ = inspectEmbeddedAuthDialogs(isExisting: false)
            return
        }
        guard let app, !app.isTerminated, isAuthHost(app) else { return }
        let fallback = app.localizedName ?? "系统授权"
        report(
            window: element, pid: pid, fallbackName: fallback, category: .systemAdmin,
            isExisting: false, inspected: UnattendedAuthAX.inspectWindow(element))
    }

    private func inspectApplicationWindows(
        pid: pid_t,
        fallbackName: String,
        category: UnattendedAuthDialogCategory,
        isExisting: Bool
    ) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        var windows = value as? [AXUIElement] ?? []
        if let focused = UnattendedAuthAX.copyElementAttribute(appElement, kAXFocusedWindowAttribute),
            !windows.contains(where: { CFEqual($0, focused) })
        {
            windows.append(focused)
        }
        for window in windows {
            report(
                window: window, pid: pid, fallbackName: fallbackName, category: category,
                isExisting: isExisting, inspected: UnattendedAuthAX.inspectWindow(window))
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
        window: AXUIElement,
        pid: pid_t,
        fallbackName: String,
        category: UnattendedAuthDialogCategory,
        isExisting: Bool,
        inspected: UnattendedAuthInspectedDialog,
        fallbackPasswordField: AXUIElement? = nil,
        manualReason: String? = nil
    ) {
        if let existing = handledWindows[pid] {
            let alive = existing.filter { UnattendedAuthAX.windowPresence($0, pid: pid) != .absent }
            handledWindows[pid] = alive.isEmpty ? nil : alive
            if alive.contains(where: { CFEqual($0, window) }) { return }
        }
        if trackedDialogs.values.contains(where: { $0.pid == pid && CFEqual($0.window, window) }) { return }
        let hasPassword = inspected.passwordField != nil
        let isTouchIDOnly = !hasPassword && inspected.usePasswordButton != nil
        if (category == .privacySettings || category == .credentialAndAppAuth || manualReason != nil)
            && !hasPassword && !isTouchIDOnly
        {
            return
        }
        guard hasPassword || isTouchIDOnly || !inspected.texts.isEmpty else { return }
        guard hasPassword || isTouchIDOnly || inspected.approveButton != nil else { return }

        let joinedText = inspected.texts.joined(separator: " ")
        let defaultPrompt =
            switch category {
            case .systemAdmin: "\(fallbackName) 管理员授权请求"
            case .privacySettings: "隐私与安全 管理员授权请求"
            case .credentialAndAppAuth: "\(fallbackName) 密码与通行密钥验证请求"
            }
        let summary = UnattendedAuthSanitizer.sanitizeText(joinedText.isEmpty ? defaultPrompt : joinedText)
        let source = UnattendedAuthSanitizer.extractRequester(from: summary, fallback: fallbackName)

        let now = clock()
        recentFingerprints = recentFingerprints.filter { now.timeIntervalSince($0.value) < 6 }
        let fingerprint = "\(category.rawValue)::\(summary)"
        if recentFingerprints[fingerprint] != nil { return }
        recentFingerprints[fingerprint] = now

        let dialogID = UUID().uuidString
        if manualReason != nil {
            markWindowHandled(window, pid: pid)
        } else {
            trackedDialogs[dialogID] = TrackedDialog(
                id: dialogID,
                pid: pid,
                window: window,
                category: category,
                fallbackPasswordField: fallbackPasswordField,
                detectedAt: now
            )
        }
        let detected = DetectedAuthDialog(
            id: dialogID,
            source: source,
            summary: summary,
            category: category,
            isExisting: isExisting,
            isTouchIDOnly: isTouchIDOnly,
            hasPasswordField: hasPassword,
            manualConfirmationReason: manualReason
        )
        onDialog?(detected)
    }
}
