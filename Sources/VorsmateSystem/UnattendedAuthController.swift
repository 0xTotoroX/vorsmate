// [INPUT]: UnattendedAuthSystemDriver、密码存储/核验协议、历史存储与可注入时钟。
// [OUTPUT]: 无人值守授权运行时状态机；管理开关、可选截止时间、锁屏一致性、密码校验与活动记录。
// [POS]: 主线程无人值守授权控制器；重启默认关闭、锁屏不改开关、密码不落盘日志。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import Foundation
import OSLog
import VorsmateCore

@MainActor
public final class UnattendedAuthController: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var hasSavedPassword = false
    @Published public private(set) var deadline: Date?
    @Published public private(set) var isScreenLocked = false
    @Published public private(set) var accessibilityTrusted = false
    @Published public private(set) var currentSession: UnattendedAuthSessionRecord?
    @Published public private(set) var history: [UnattendedAuthSessionRecord] = []
    @Published public private(set) var statusBannerMessage: String?
    @Published public private(set) var passwordInvalidated = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var now: Date

    private let driver: any UnattendedAuthSystemDriver
    private let passwordStore: any UnattendedAuthPasswordStore
    private let passwordVerifier: any UnattendedAuthPasswordVerifier
    private let historyStore: UnattendedAuthHistoryStore
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let tickInterval: Duration
    private let logger = Logger(subsystem: "app.vorsmate.mac", category: "UnattendedAuth")

    private var active = false
    private var generation = 0
    private var tickerTask: Task<Void, Never>?
    private var approvalTasks: [UUID: Task<Void, Never>] = [:]

    public var isPreview: Bool { driver.isPreview }

    public var fullStatusText: String {
        UnattendedAuthStatusFormatter.fullStatus(isEnabled: isEnabled, deadline: deadline, now: now)
    }

    public var menuBarTitle: String? {
        UnattendedAuthStatusFormatter.menuBarTitle(isEnabled: isEnabled, deadline: deadline, now: now)
    }

    public var summaryStatusText: String {
        UnattendedAuthStatusFormatter.summaryStatus(
            isEnabled: isEnabled,
            hasSavedPassword: hasSavedPassword,
            passwordInvalidated: passwordInvalidated,
            deadline: deadline,
            now: now
        )
    }

    public var summaryValueText: String {
        UnattendedAuthStatusFormatter.summaryValue(
            isEnabled: isEnabled,
            passwordInvalidated: passwordInvalidated,
            deadline: deadline,
            now: now
        )
    }

    public init(
        driver: any UnattendedAuthSystemDriver,
        passwordStore: any UnattendedAuthPasswordStore,
        passwordVerifier: any UnattendedAuthPasswordVerifier,
        historyStore: UnattendedAuthHistoryStore = .standard,
        clock: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        tickInterval: Duration = .seconds(1)
    ) {
        self.driver = driver
        self.passwordStore = passwordStore
        self.passwordVerifier = passwordVerifier
        self.historyStore = historyStore
        self.clock = clock
        self.sleep = sleep
        self.tickInterval = tickInterval
        self.now = clock()
    }

    public func activate() {
        guard !active else { return }
        active = true
        now = clock()
        // 启动与重启后始终默认关闭，不自动恢复上次会话。
        isEnabled = false
        deadline = nil
        currentSession = nil
        history = historyStore.load()
        refresh()
    }

    public func deactivate() {
        guard active else { return }
        if isEnabled {
            disable(reason: .pluginDisabled)
        }
        active = false
    }

    public func terminate() {
        if isEnabled {
            disable(reason: .appTerminated)
        }
        active = false
    }

    public func refresh() {
        guard active else { return }
        now = clock()
        hasSavedPassword = passwordStore.hasPassword()
        accessibilityTrusted = driver.isAccessibilityTrusted()
        isScreenLocked = driver.isScreenCurrentlyLocked()
        reconcileDeadlineAndHealth()
    }

    public func panelDidChangeVisibility(_ visible: Bool) {
        if visible { refresh() }
    }

    public func requestAccessibilityTrust() {
        driver.requestAccessibilityTrust()
        accessibilityTrusted = driver.isAccessibilityTrusted()
    }

    public func openAccessibilitySettings() {
        driver.openAccessibilitySettings()
    }

    @discardableResult
    public func savePassword(_ password: String) -> Bool {
        errorMessage = nil
        guard !password.isEmpty else {
            errorMessage = "请输入管理员密码。"
            return false
        }
        switch passwordVerifier.verifyPassword(password) {
        case .valid:
            break
        case .invalid:
            errorMessage = "管理员密码不正确，请核对后重试。"
            return false
        case .unavailable(let reason):
            errorMessage = reason
            return false
        }
        do {
            try passwordStore.savePassword(password)
            hasSavedPassword = true
            passwordInvalidated = false
            statusBannerMessage = nil
            errorMessage = nil
            logger.info("Admin password saved in local Keychain.")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func deletePassword() {
        errorMessage = nil
        do {
            try passwordStore.deletePassword()
            hasSavedPassword = false
            passwordInvalidated = false
            if isEnabled {
                disable(reason: .passwordDeleted)
            } else {
                statusBannerMessage = nil
            }
            logger.info("Admin password deleted from local Keychain.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func enable(deadlineChoice: UnattendedAuthDeadlineChoice) -> Bool {
        guard active else { return false }
        errorMessage = nil
        statusBannerMessage = nil
        now = clock()
        hasSavedPassword = passwordStore.hasPassword()
        accessibilityTrusted = driver.isAccessibilityTrusted()

        guard hasSavedPassword else {
            errorMessage = "请先录入管理员密码。"
            return false
        }
        guard accessibilityTrusted else {
            errorMessage = "开启前需授予 Vorsmate 辅助功能权限。"
            return false
        }

        let password: String
        do {
            guard let loaded = try passwordStore.loadPassword(), !loaded.isEmpty else {
                hasSavedPassword = false
                errorMessage = "请先录入管理员密码。"
                return false
            }
            password = loaded
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        switch passwordVerifier.verifyPassword(password) {
        case .valid:
            passwordInvalidated = false
        case .invalid:
            passwordInvalidated = true
            statusBannerMessage = "已保存的管理员密码已失效，请更新密码后重新开启。"
            return false
        case .unavailable(let reason):
            errorMessage = reason
            return false
        }

        let resolvedDeadline = deadlineChoice.resolveDeadline(from: now)
        if deadlineChoice.requiresFutureDeadline && resolvedDeadline == nil {
            if case .durationMinutes(let minutes) = deadlineChoice,
                minutes > UnattendedAuthDeadlineChoice.maxCustomMinutes
            {
                errorMessage = "授权时长最长支持 \(UnattendedAuthDeadlineChoice.maxCustomMinutes) 分钟（24 小时）。"
            } else {
                errorMessage = "截止时间需晚于当前时间。"
            }
            return false
        }

        do {
            try driver.startMonitoring(
                onDialog: { [weak self] dialog in self?.handleDetectedDialog(dialog) },
                onScreenLockChanged: { [weak self] locked in self?.handleScreenLockChanged(locked) },
                onWake: { [weak self] in self?.handleSystemWake() }
            )
        } catch {
            errorMessage = "无法启动授权监听：\(error.localizedDescription)"
            return false
        }

        generation += 1
        isEnabled = true
        deadline = resolvedDeadline
        isScreenLocked = driver.isScreenCurrentlyLocked()
        currentSession = UnattendedAuthSessionRecord(startedAt: now, deadline: resolvedDeadline)
        startTicker(token: generation)
        logger.info("Unattended authorization enabled. hasDeadline=\(resolvedDeadline != nil, privacy: .public)")
        driver.checkExistingDialogs()
        return isEnabled
    }

    public func disable(reason: UnattendedAuthStopReason = .manual, at endTime: Date? = nil) {
        guard isEnabled else { return }
        generation += 1
        tickerTask?.cancel()
        tickerTask = nil
        for task in approvalTasks.values { task.cancel() }
        approvalTasks = [:]
        driver.stopMonitoring()

        let closedAt = endTime ?? clock()
        now = closedAt
        isEnabled = false
        deadline = nil

        if var session = currentSession {
            session.endedAt = closedAt
            session.stopReason = reason
            history.insert(session, at: 0)
            if history.count > UnattendedAuthHistoryStore.maxSessions {
                history = Array(history.prefix(UnattendedAuthHistoryStore.maxSessions))
            }
            currentSession = nil
            persistHistory()
        }

        switch reason {
        case .manual:
            statusBannerMessage = nil
        case .deadlineReached:
            statusBannerMessage = "已到达截止时间，无人值守授权已自动关闭。"
        case .passwordInvalid:
            passwordInvalidated = true
            statusBannerMessage = "已保存的管理员密码已失效，已自动关闭。请更新密码。"
        case .passwordDeleted:
            statusBannerMessage = "已删除管理员密码，无人值守授权已关闭。"
        case .pluginDisabled, .appTerminated:
            statusBannerMessage = nil
        }
        logger.info("Unattended authorization disabled. reason=\(reason.rawValue, privacy: .public)")
    }

    public func clearHistory() {
        history = []
        persistHistory()
    }

    public func reconcileDeadlineAndHealth() {
        now = clock()
        guard isEnabled else { return }
        if let deadline, now >= deadline {
            disable(reason: .deadlineReached, at: deadline)
            return
        }
        if !passwordStore.hasPassword() {
            hasSavedPassword = false
            disable(reason: .passwordDeleted)
        }
    }

    public func handleScreenLockChanged(_ locked: Bool) {
        // 锁屏本身不改变开关状态；解锁或锁屏时均按墙钟核对截止时间与状态健康。
        isScreenLocked = locked
        reconcileDeadlineAndHealth()
        guard isEnabled, !locked else { return }
        accessibilityTrusted = driver.isAccessibilityTrusted()
        if let password = try? passwordStore.loadPassword(),
            case .invalid = passwordVerifier.verifyPassword(password)
        {
            disable(reason: .passwordInvalid)
        }
    }

    public func handleSystemWake() {
        reconcileDeadlineAndHealth()
    }

    public func handleDetectedDialog(_ dialog: DetectedAuthDialog) {
        guard isEnabled else { return }
        reconcileDeadlineAndHealth()
        guard isEnabled else { return }

        let token = generation
        let detectedAt = clock()

        let password: String
        do {
            guard let loaded = try passwordStore.loadPassword(), !loaded.isEmpty else {
                hasSavedPassword = false
                appendEvent(
                    UnattendedAuthDialogEvent(
                        timestamp: detectedAt,
                        source: dialog.source,
                        summary: UnattendedAuthSanitizer.sanitizeText(dialog.summary),
                        outcome: .leftForUser,
                        detail: "未找到已保存密码"
                    ))
                disable(reason: .passwordDeleted)
                return
            }
            password = loaded
        } catch {
            appendEvent(
                UnattendedAuthDialogEvent(
                    timestamp: detectedAt,
                    source: dialog.source,
                    summary: UnattendedAuthSanitizer.sanitizeText(dialog.summary),
                    outcome: .blocked,
                    detail: "无法读取本机钥匙串"
                ))
            return
        }

        let safeSummary = UnattendedAuthSanitizer.sanitizeText(dialog.summary, excludingSecret: password)
        let safeSource = UnattendedAuthSanitizer.sanitizeText(dialog.source, excludingSecret: password)

        if let reason = dialog.manualConfirmationReason {
            appendEvent(
                UnattendedAuthDialogEvent(
                    timestamp: detectedAt, source: safeSource, summary: safeSummary,
                    outcome: .leftForUser, detail: reason))
            return
        }

        if case .invalid = passwordVerifier.verifyPassword(password) {
            appendEvent(
                UnattendedAuthDialogEvent(
                    timestamp: detectedAt,
                    source: safeSource,
                    summary: safeSummary,
                    outcome: .passwordInvalid,
                    detail: "密码已失效，保留由本人确认"
                ))
            disable(reason: .passwordInvalid)
            return
        }

        let taskID = UUID()
        let activeDeadline = deadline
        approvalTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.approvalTasks.removeValue(forKey: taskID)
                }
            }
            guard self.isEnabled, self.generation == token, !Task.isCancelled else { return }
            if let currentDeadline = self.deadline, self.clock() >= currentDeadline {
                self.disable(reason: .deadlineReached, at: currentDeadline)
                return
            }

            let result = await self.driver.approveDialog(id: dialog.id, password: password, deadline: activeDeadline)

            let withinDeadline = self.deadline.map { self.clock() < $0 } ?? true
            guard self.isEnabled, self.generation == token, !Task.isCancelled, withinDeadline else {
                if !withinDeadline, self.isEnabled, self.generation == token {
                    self.reconcileDeadlineAndHealth()
                }
                // 在提交完成前已被手动关闭或到期停止：若已批准，记入刚结束的会话。
                if case .approved(let detail) = result {
                    self.appendEventToLatestClosedSession(
                        UnattendedAuthDialogEvent(
                            timestamp: detectedAt,
                            source: safeSource,
                            summary: safeSummary,
                            outcome: .approved,
                            detail: detail
                        ))
                }
                return
            }

            switch result {
            case .approved(let detail):
                self.appendEvent(
                    UnattendedAuthDialogEvent(
                        timestamp: detectedAt,
                        source: safeSource,
                        summary: safeSummary,
                        outcome: .approved,
                        detail: detail
                    ))
            case .blocked(let reason):
                self.appendEvent(
                    UnattendedAuthDialogEvent(
                        timestamp: detectedAt,
                        source: safeSource,
                        summary: safeSummary,
                        outcome: .blocked,
                        detail: reason
                    ))
            case .leftForUser(let reason):
                self.appendEvent(
                    UnattendedAuthDialogEvent(
                        timestamp: detectedAt,
                        source: safeSource,
                        summary: safeSummary,
                        outcome: .leftForUser,
                        detail: reason
                    ))
            case .passwordRejected(let reason):
                if case .invalid = self.passwordVerifier.verifyPassword(password) {
                    self.appendEvent(
                        UnattendedAuthDialogEvent(
                            timestamp: detectedAt,
                            source: safeSource,
                            summary: safeSummary,
                            outcome: .passwordInvalid,
                            detail: reason
                        ))
                    self.disable(reason: .passwordInvalid)
                } else {
                    self.appendEvent(
                        UnattendedAuthDialogEvent(
                            timestamp: detectedAt,
                            source: safeSource,
                            summary: safeSummary,
                            outcome: .blocked,
                            detail: reason
                        ))
                }
            }
        }
    }

    public func loadPreviewSampleHistory(now reference: Date) {
        guard isPreview else { return }
        history = [
            UnattendedAuthSessionRecord(
                startedAt: reference.addingTimeInterval(-3600),
                endedAt: reference.addingTimeInterval(-1800),
                deadline: reference.addingTimeInterval(-1800),
                stopReason: .deadlineReached,
                events: [
                    UnattendedAuthDialogEvent(
                        timestamp: reference.addingTimeInterval(-2900),
                        source: "zsh",
                        summary: "zsh 想要进行更改。输入您的密码以允许此操作。",
                        outcome: .blocked,
                        detail: "弹窗未关闭，已保留由本人确认"
                    )
                ]
            )
        ]
    }

    private func startTicker(token: Int) {
        tickerTask?.cancel()
        tickerTask = Task { [weak self, sleep, tickInterval] in
            while !Task.isCancelled {
                try? await sleep(tickInterval)
                guard !Task.isCancelled else { return }
                guard let self, self.isEnabled, self.generation == token else { return }
                self.reconcileDeadlineAndHealth()
            }
        }
    }

    private func appendEvent(_ event: UnattendedAuthDialogEvent) {
        guard var session = currentSession else { return }
        session.events.insert(event, at: 0)
        currentSession = session
    }

    private func appendEventToLatestClosedSession(_ event: UnattendedAuthDialogEvent) {
        guard !history.isEmpty else { return }
        history[0].events.insert(event, at: 0)
        persistHistory()
    }

    private func persistHistory() {
        try? historyStore.save(history)
    }
}
