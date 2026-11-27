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
    private static let existingDialogManualReason = "开启前已存在的请求由本人确认"
    private static let privacyDialogManualReason = "隐私与安全请求由本人确认"

    private struct TrackedDialog {
        let id: String
        let pid: pid_t
        let window: AXUIElement
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
    private var privacyApplicationObserver: NSKeyValueObservation?
    private var privacyScanTask: Task<Void, Never>?
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
        registerPrivacyProcessObserver(monitoringID: id)
    }

    public func checkExistingDialogs() {
        guard monitoring else { return }
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && isAuthHost(app) {
            attachAXObserver(for: app)
            inspectApplicationWindows(
                pid: app.processIdentifier,
                fallbackName: app.localizedName ?? "系统授权",
                manualReason: Self.existingDialogManualReason)
        }
        attachPrivacyObservers()
        _ = inspectPrivacySettingsDialogs(manualReason: Self.existingDialogManualReason)
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
            isAuthHost(hostApp)
        else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .blocked(reason: "无法验证系统授权弹窗签名身份，已保留由本人确认")
        }

        if let unavailable = checkWindowPresentOrStop(tracked) { return unavailable }

        var inspected = UnattendedAuthAX.inspectWindow(tracked.window)
        if inspected.passwordField == nil, let usePasswordButton = inspected.usePasswordButton {
            guard AXUIElementPerformAction(usePasswordButton, kAXPressAction as CFString) == .success else {
                markWindowHandled(tracked.window, pid: tracked.pid)
                return .blocked(reason: "触控 ID 界面无法切换到密码输入，已保留由本人确认")
            }
            try? await Task.sleep(for: .milliseconds(350))
            if let stopped = checkSubmissionAllowed(monitoringID: capturedMonitoringID, deadline: deadline) {
                return stopped
            }
            if let unavailable = checkWindowPresentOrStop(tracked) { return unavailable }
            inspected = UnattendedAuthAX.inspectWindow(tracked.window)
        }

        guard let passwordField = inspected.passwordField else {
            markWindowHandled(tracked.window, pid: tracked.pid)
            return .leftForUser(reason: "未识别到管理员密码输入框，已保留由本人确认")
        }

        guard let inputPID = verifiedInputPID(for: passwordField, fallbackHostPID: tracked.pid) else {
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

    private func registerPrivacyProcessObserver(monitoringID id: UUID) {
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

    private func verifiedInputPID(for passwordField: AXUIElement, fallbackHostPID: pid_t) -> pid_t? {
        var fieldPID: pid_t = 0
        AXUIElementGetPid(passwordField, &fieldPID)
        let inputPID = fieldPID != 0 ? fieldPID : fallbackHostPID
        if inputPID == fallbackHostPID {
            return Self.isVerifiedAppleProcess(pid: inputPID) ? inputPID : nil
        }
        guard let inputApp = NSRunningApplication(processIdentifier: inputPID),
            !inputApp.isTerminated,
            isAuthHost(inputApp)
        else { return nil }
        return inputPID
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
        let afterTexts = UnattendedAuthAX.inspectWindow(tracked.window).texts.joined(separator: " ")
        if Self.isPasswordRejectedText(afterTexts) {
            return .passwordRejected(reason: "系统提示密码未通过验证")
        }
        return .blocked(reason: "弹窗未关闭，已保留由本人确认")
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

    private func inspectPrivacySettingsDialogs(manualReason: String = privacyDialogManualReason) -> Bool {
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
                window: sheet, pid: pid, fallbackName: "隐私与安全", inspected: inspected, manualReason: manualReason)
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
            if UnattendedAuthAX.copyStringAttribute(element, kAXRoleAttribute) == kAXSheetRole {
                let inspected = UnattendedAuthAX.inspectWindow(element)
                if inspected.passwordField != nil || inspected.usePasswordButton != nil {
                    report(
                        window: element, pid: pid, fallbackName: "隐私与安全", inspected: inspected,
                        manualReason: Self.privacyDialogManualReason)
                }
            } else {
                _ = inspectPrivacySettingsDialogs(manualReason: Self.privacyDialogManualReason)
            }
            return
        }
        guard let app, !app.isTerminated, isAuthHost(app) else { return }
        let fallback = app.localizedName ?? "系统授权"
        report(window: element, pid: pid, fallbackName: fallback, inspected: UnattendedAuthAX.inspectWindow(element))
    }

    private func inspectApplicationWindows(pid: pid_t, fallbackName: String, manualReason: String? = nil) {
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
                window: window, pid: pid, fallbackName: fallbackName,
                inspected: UnattendedAuthAX.inspectWindow(window), manualReason: manualReason)
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
        inspected: UnattendedAuthInspectedDialog,
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
            let now = clock()
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
}
