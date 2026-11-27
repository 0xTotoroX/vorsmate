// [INPUT]: 可注入时钟、可控异步休眠器、内存密码存储/核验与授权驱动替身。
// [OUTPUT]: 无人值守授权的开关、截止时间、锁屏一致性、弹窗处理、密码管理、脱敏持久化与停用回归测试。
// [POS]: VorsmateCoreTests 纯内存无硬件验收测试，绝不触碰真实 Keychain、辅助功能或锁屏。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateSystem

@Suite("无人值守授权模式")
@MainActor
struct UnattendedAuthTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_760_000_400)  // 整秒，便于 ISO8601 精确往返

    @Test("激活与模拟应用重启后始终默认关闭")
    func defaultOffOnActivateAndSimulatedRestart() {
        let clock = MutableTestClock(Self.baseDate)
        let passwordStore = InMemoryUnattendedPasswordStore(initialPassword: "Admin#2026")
        let verifier = MutablePasswordVerifier(expected: "Admin#2026")
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let historyStore = UnattendedAuthHistoryStore(url: dir.appending(path: "history.json"))

        let firstDriver = FakeUnattendedAuthDriver()
        let first = UnattendedAuthController(
            driver: firstDriver,
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: historyStore,
            clock: { clock.now() }
        )
        first.activate()
        #expect(!first.isEnabled)
        #expect(first.deadline == nil)
        #expect(first.currentSession == nil)
        #expect(first.menuBarTitle == nil)
        #expect(first.fullStatusText == "已关闭")
        #expect(first.hasSavedPassword)

        #expect(first.enable(deadlineChoice: .durationMinutes(30)))
        #expect(first.isEnabled)
        first.terminate()
        #expect(!first.isEnabled)
        #expect(!firstDriver.isMonitoring)
        #expect(first.history.first?.stopReason == .appTerminated)

        // 模拟正常退出后重新启动
        let secondDriver = FakeUnattendedAuthDriver()
        let second = UnattendedAuthController(
            driver: secondDriver,
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: historyStore,
            clock: { clock.now() }
        )
        second.activate()
        #expect(!second.isEnabled)
        #expect(second.deadline == nil)
        #expect(second.currentSession == nil)
        #expect(second.hasSavedPassword)
        #expect(!secondDriver.isMonitoring)
        #expect(second.history.first?.stopReason == .appTerminated)

        // 模拟未调用 terminate 直接重建控制器的异常重启
        #expect(second.enable(deadlineChoice: .none))
        #expect(second.isEnabled)
        let thirdDriver = FakeUnattendedAuthDriver()
        let third = UnattendedAuthController(
            driver: thirdDriver,
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: historyStore,
            clock: { clock.now() }
        )
        third.activate()
        #expect(!third.isEnabled)
        #expect(third.deadline == nil)
        #expect(third.currentSession == nil)
        #expect(!thirdDriver.isMonitoring)
        second.deactivate()
    }

    @Test("未录入密码或缺少辅助功能权限时禁止开启")
    func enableRejectedWithoutPasswordOrAccessibility() {
        let driver = FakeUnattendedAuthDriver()
        let passwordStore = InMemoryUnattendedPasswordStore()
        let verifier = MutablePasswordVerifier(expected: "Admin#2026")
        let controller = UnattendedAuthController(
            driver: driver,
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: .inMemory
        )
        controller.activate()

        #expect(!controller.enable(deadlineChoice: .none))
        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.errorMessage == "请先录入管理员密码。")
        #expect(controller.summaryStatusText == "未配置密码")
        #expect(controller.summaryValueText == "未开启")

        #expect(controller.savePassword("Admin#2026"))
        driver.trusted = false
        #expect(!controller.enable(deadlineChoice: .none))
        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.errorMessage == "开启前需授予 Vorsmate 辅助功能权限。")
    }

    @Test("密码录入校验拒绝空密码、错密码与核验不可用，接受正确密码")
    func passwordValidationRules() throws {
        let driver = FakeUnattendedAuthDriver()
        let passwordStore = InMemoryUnattendedPasswordStore()
        let verifier = MutablePasswordVerifier(expected: "Admin#2026")
        let controller = UnattendedAuthController(
            driver: driver,
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: .inMemory
        )
        controller.activate()

        #expect(!controller.savePassword(""))
        #expect(!controller.hasSavedPassword)
        #expect(controller.errorMessage == "请输入管理员密码。")

        #expect(!controller.savePassword("WrongPassword"))
        #expect(!controller.hasSavedPassword)
        #expect(controller.errorMessage == "管理员密码不正确，请核对后重试。")

        verifier.setUnavailable("无法核验本机账户密码：测试不可用")
        #expect(!controller.savePassword("Admin#2026"))
        #expect(!controller.hasSavedPassword)
        #expect(controller.errorMessage == "无法核验本机账户密码：测试不可用")

        verifier.setExpected("Admin#2026")
        #expect(controller.savePassword("Admin#2026"))
        #expect(controller.hasSavedPassword)
        #expect(!controller.passwordInvalidated)
        #expect(controller.errorMessage == nil)
        #expect(try passwordStore.loadPassword() == "Admin#2026")
    }

    @Test("未设截止时间开启不含到期或剩余时长文案且可随时手动关闭")
    func enableWithoutDeadlineOmitsExpiryAndManualDisable() {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock)

        #expect(controller.enable(deadlineChoice: .none))
        #expect(controller.isEnabled)
        #expect(controller.deadline == nil)
        #expect(driver.isMonitoring)

        let forbiddenFragments = ["至", "剩余", ":", "分钟", "小时", "秒"]
        let texts = [
            controller.fullStatusText,
            controller.menuBarTitle ?? "",
            controller.summaryStatusText,
            controller.summaryValueText,
        ]
        #expect(controller.fullStatusText == "无人值守授权已开启 · 手动关闭")
        #expect(controller.menuBarTitle == "无人值守")
        #expect(controller.summaryStatusText == "已开启 · 手动关闭")
        #expect(controller.summaryValueText == "运行中")
        for text in texts {
            for fragment in forbiddenFragments {
                #expect(!text.contains(fragment))
            }
        }

        clock.advance(by: 120)
        controller.disable(reason: .manual)
        #expect(!controller.isEnabled)
        #expect(controller.deadline == nil)
        #expect(controller.menuBarTitle == nil)
        #expect(controller.fullStatusText == "已关闭")
        #expect(controller.summaryStatusText == "已关闭")
        #expect(controller.summaryValueText == "未开启")
        #expect(!driver.isMonitoring)
        #expect(controller.history.count == 1)
        #expect(controller.history[0].stopReason == .manual)
        #expect(controller.history[0].deadline == nil)
        #expect(controller.history[0].endedAt == Self.baseDate.addingTimeInterval(120))
    }

    @Test("按时长和按指定时刻开启拒绝过去时间、准确展示剩余时长并在到期时自动关闭")
    func deadlineDurationSpecificDateRejectPastAndAutoExpire() async {
        let clock = MutableTestClock(Self.baseDate)
        let sleeper = TestSleeper()
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock, sleeper: sleeper)

        // 拒绝非正时长、超上限（> 1440 分钟）与过去/当前时刻，且不发生整数溢出
        #expect(UnattendedAuthPolicy.maxCustomMinutes == 1440)
        #expect(UnattendedAuthDeadlineChoice.durationMinutes(1440).resolveDeadline(from: Self.baseDate) != nil)
        #expect(UnattendedAuthDeadlineChoice.durationMinutes(1441).resolveDeadline(from: Self.baseDate) == nil)
        #expect(UnattendedAuthDeadlineChoice.durationMinutes(Int.max).resolveDeadline(from: Self.baseDate) == nil)
        #expect(!controller.enable(deadlineChoice: .durationMinutes(0)))
        #expect(controller.errorMessage == "截止时间需晚于当前时间。")
        #expect(!controller.enable(deadlineChoice: .durationMinutes(1441)))
        #expect(controller.errorMessage == "授权时长最长支持 1440 分钟（24 小时）。")
        #expect(!controller.enable(deadlineChoice: .durationMinutes(-5)))
        #expect(!controller.enable(deadlineChoice: .specificDate(Self.baseDate)))
        #expect(!controller.enable(deadlineChoice: .specificDate(Self.baseDate.addingTimeInterval(-60))))
        #expect(!controller.isEnabled)

        // 按时长 25 分钟开启
        #expect(controller.enable(deadlineChoice: .durationMinutes(25)))
        let durationDeadline = Self.baseDate.addingTimeInterval(25 * 60)
        #expect(controller.isEnabled)
        #expect(controller.deadline == durationDeadline)
        #expect(controller.fullStatusText.contains("无人值守授权已开启 · 至 "))
        #expect(controller.fullStatusText.contains("剩余 25 分钟"))
        #expect(controller.menuBarTitle == "无人值守 · 剩余 25 分钟")
        #expect(controller.summaryStatusText.hasPrefix("已开启 · 至 "))
        #expect(controller.summaryValueText == "剩余 25 分钟")

        // 推进至超过截止时间，由定时器触发到期自动关闭
        clock.advance(by: 25 * 60 + 5)
        await sleeper.tick()
        #expect(!controller.isEnabled)
        #expect(controller.deadline == nil)
        #expect(controller.menuBarTitle == nil)
        #expect(!driver.isMonitoring)
        #expect(controller.history.count == 1)
        #expect(controller.history.first?.stopReason == .deadlineReached)
        #expect(controller.history.first?.deadline == durationDeadline)
        #expect(controller.history.first?.endedAt == durationDeadline)
        #expect(controller.statusBannerMessage?.contains("截止时间") == true)

        // 按指定时刻（+90 分钟）开启
        let specificStart = clock.now()
        let specificTarget = specificStart.addingTimeInterval(90 * 60)
        #expect(controller.enable(deadlineChoice: .specificDate(specificTarget)))
        #expect(controller.isEnabled)
        #expect(controller.deadline == specificTarget)
        #expect(controller.menuBarTitle == "无人值守 · 剩余 1 小时 30 分钟")
        #expect(controller.summaryValueText == "剩余 1 小时 30 分钟")
        #expect(controller.fullStatusText.contains("剩余 1 小时 30 分钟"))

        clock.advance(by: 90 * 60)
        controller.reconcileDeadlineAndHealth()
        #expect(!controller.isEnabled)
        #expect(controller.history.count == 2)
        #expect(controller.history.first?.stopReason == .deadlineReached)
        #expect(controller.history.first?.endedAt == specificTarget)
    }

    @Test("状态文案格式化覆盖当日、次日、跨日与秒/分/小时粒度")
    func statusFormatterCalendarAndUnits() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 14, minute: 0))!
        let sameDay = calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 14, minute: 30))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 5, day: 11, hour: 9, minute: 15))!
        let laterDay = calendar.date(from: DateComponents(year: 2026, month: 5, day: 13, hour: 8, minute: 5))!

        #expect(UnattendedAuthStatusFormatter.deadlineClockText(sameDay, now: now, calendar: calendar) == "14:30")
        #expect(UnattendedAuthStatusFormatter.deadlineClockText(nextDay, now: now, calendar: calendar) == "明日 09:15")
        #expect(
            UnattendedAuthStatusFormatter.deadlineClockText(laterDay, now: now, calendar: calendar) == "5月13日 08:05")
        #expect(
            UnattendedAuthStatusFormatter.remainingText(until: now.addingTimeInterval(45), now: now) == "剩余 45 秒")
        #expect(
            UnattendedAuthStatusFormatter.remainingText(until: now.addingTimeInterval(120 * 60), now: now)
                == "剩余 2 小时")
    }

    @Test("未设截止时间时锁屏与解锁全程保持开启")
    func lockAndUnlockWithoutDeadlineKeepsSessionActive() async {
        let clock = MutableTestClock(Self.baseDate)
        let sleeper = TestSleeper()
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock, sleeper: sleeper)

        #expect(controller.enable(deadlineChoice: .none))
        let sessionID = controller.currentSession?.id
        #expect(sessionID != nil)

        driver.emitScreenLockChanged(true)
        #expect(controller.isScreenLocked)
        #expect(controller.isEnabled)
        #expect(driver.isMonitoring)
        #expect(controller.currentSession?.id == sessionID)

        clock.advance(by: 2 * 3600)
        await sleeper.tick()
        #expect(controller.isEnabled)
        #expect(controller.deadline == nil)

        driver.emitScreenLockChanged(false)
        #expect(!controller.isScreenLocked)
        #expect(controller.isEnabled)
        #expect(driver.isMonitoring)
        #expect(controller.currentSession?.id == sessionID)
        #expect(controller.history.isEmpty)
        controller.deactivate()
    }

    @Test("已设截止时间且锁屏期间未到期，解锁保持开启并准确更新剩余时长")
    func lockAndUnlockBeforeDeadlineUpdatesRemaining() {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock)

        #expect(controller.enable(deadlineChoice: .durationMinutes(30)))
        let sessionID = controller.currentSession?.id
        driver.emitScreenLockChanged(true)
        #expect(controller.isScreenLocked)
        #expect(controller.isEnabled)

        clock.advance(by: 12 * 60)
        driver.emitScreenLockChanged(false)
        #expect(!controller.isScreenLocked)
        #expect(controller.isEnabled)
        #expect(controller.currentSession?.id == sessionID)
        #expect(controller.summaryValueText == "剩余 18 分钟")
        #expect(controller.menuBarTitle == "无人值守 · 剩余 18 分钟")
        #expect(controller.history.isEmpty)
        controller.deactivate()
    }

    @Test("已设截止时间且锁屏期间到期，触发核对或解锁后自动关闭并如实展示到期记录")
    func deadlineReachedDuringScreenLockAutoDisables() {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock)

        // 场景 A：锁屏期间越过截止时间，解锁触发关闭
        #expect(controller.enable(deadlineChoice: .durationMinutes(10)))
        let firstDeadline = Self.baseDate.addingTimeInterval(10 * 60)
        driver.emitScreenLockChanged(true)
        clock.advance(by: 15 * 60)
        driver.emitScreenLockChanged(false)

        #expect(!controller.isScreenLocked)
        #expect(!controller.isEnabled)
        #expect(controller.deadline == nil)
        #expect(controller.menuBarTitle == nil)
        #expect(controller.fullStatusText == "已关闭")
        #expect(!driver.isMonitoring)
        #expect(controller.history.first?.stopReason == .deadlineReached)
        #expect(controller.history.first?.endedAt == firstDeadline)
        #expect(controller.statusBannerMessage?.contains("截止时间") == true)

        // 场景 B：锁屏期间越过截止时间，先由 reconcileDeadlineAndHealth 自动关闭，再解锁仍展示已关闭
        let secondStart = clock.now()
        let secondDeadline = secondStart.addingTimeInterval(10 * 60)
        #expect(controller.enable(deadlineChoice: .durationMinutes(10)))
        driver.emitScreenLockChanged(true)
        clock.advance(by: 12 * 60)
        controller.reconcileDeadlineAndHealth()

        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.history.first?.stopReason == .deadlineReached)
        #expect(controller.history.first?.endedAt == secondDeadline)

        controller.handleScreenLockChanged(false)
        #expect(!controller.isScreenLocked)
        #expect(!controller.isEnabled)
        #expect(controller.fullStatusText == "已关闭")
        #expect(controller.history.first?.stopReason == .deadlineReached)
    }

    @Test("锁屏期间密码失效，解锁核验后自动关闭并标记密码失效")
    func passwordInvalidatedDuringScreenLockDisablesOnUnlock() {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let verifier = MutablePasswordVerifier(expected: "Admin#2026")
        let controller = makeReadyController(driver: driver, verifier: verifier, clock: clock)

        #expect(controller.enable(deadlineChoice: .none))
        driver.emitScreenLockChanged(true)
        #expect(controller.isEnabled)
        #expect(controller.isScreenLocked)

        verifier.setExpected("ChangedWhileLocked#99")
        driver.emitScreenLockChanged(false)

        #expect(!controller.isScreenLocked)
        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.passwordInvalidated)
        #expect(controller.summaryStatusText == "密码已失效")
        #expect(controller.summaryValueText == "需更新")
        #expect(controller.history.first?.stopReason == .passwordInvalid)
        #expect(controller.statusBannerMessage?.contains("更新密码") == true)
    }

    @Test("锁屏保持开启不影响应用重启后恢复默认关闭")
    func lockScreenActiveDoesNotPreventRestartDefaultOff() {
        let clock = MutableTestClock(Self.baseDate)
        let passwordStore = InMemoryUnattendedPasswordStore(initialPassword: "Admin#2026")
        let verifier = MutablePasswordVerifier(expected: "Admin#2026")
        let driver1 = FakeUnattendedAuthDriver()
        let controller1 = UnattendedAuthController(
            driver: driver1,
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: .inMemory,
            clock: { clock.now() }
        )
        controller1.activate()
        #expect(controller1.enable(deadlineChoice: .none))
        driver1.emitScreenLockChanged(true)
        #expect(controller1.isEnabled)
        #expect(controller1.isScreenLocked)

        // 模拟重启重建控制器
        let driver2 = FakeUnattendedAuthDriver()
        let controller2 = UnattendedAuthController(
            driver: driver2,
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: .inMemory,
            clock: { clock.now() }
        )
        controller2.activate()
        #expect(!controller2.isEnabled)
        #expect(controller2.deadline == nil)
        #expect(controller2.currentSession == nil)
        #expect(!driver2.isMonitoring)
        controller1.deactivate()
    }

    @Test("关闭状态下收到弹窗回调完全不介入且不写事件")
    func disabledStateIgnoresDialogCallbacks() async {
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver)
        #expect(!controller.isEnabled)

        controller.handleDetectedDialog(
            DetectedAuthDialog(id: "d1", source: "zsh", summary: "zsh 想要进行更改"))
        await settle()

        #expect(driver.approvalCalls.isEmpty)
        #expect(controller.currentSession == nil)
        #expect(controller.history.isEmpty)
    }

    @Test("默认全部自动批准，按选项区分保留本人确认或放行，并支持运行中切换与持久化")
    func approvalOptionsRouteCategoriesAndExistingDialogs() async {
        let driver = FakeUnattendedAuthDriver()
        driver.existingDialogs = [
            DetectedAuthDialog(
                id: "existing-admin", source: "终端", summary: "终端想要进行更改",
                category: .systemAdmin, isExisting: true)
        ]
        driver.defaultApprovalResult = .approved(detail: "已提交授权且弹窗已关闭")

        var persisted: [UnattendedAuthPreferences] = []
        let controller = UnattendedAuthController(
            driver: driver,
            passwordStore: InMemoryUnattendedPasswordStore(initialPassword: "Admin#2026"),
            passwordVerifier: MutablePasswordVerifier(expected: "Admin#2026"),
            historyStore: .inMemory,
            preferences: UnattendedAuthPreferences(),
            persist: { persisted.append($0) }
        )
        controller.activate()

        // 1. 默认选项下全部类别（含开启前已存在、隐私与安全、密码与通行密钥）均进入自动批准
        #expect(controller.preferences.optionsSummaryText == "全部")
        #expect(controller.enable(deadlineChoice: .none))
        await settle()
        #expect(driver.approvalCalls.map(\.id) == ["existing-admin"])
        #expect(controller.currentSession?.events.first?.outcome == .approved)

        driver.emitDialog(
            DetectedAuthDialog(
                id: "privacy-auto", source: "隐私与安全", summary: "正在尝试修改你的系统设置",
                category: .privacySettings))
        await settle()
        driver.emitDialog(
            DetectedAuthDialog(
                id: "passkey-auto", source: "ego lite", summary: "通过“user@example.com”登录。输入密码以解锁。",
                category: .credentialAndAppAuth))
        await settle()
        #expect(driver.approvalCalls.map(\.id) == ["existing-admin", "privacy-auto", "passkey-auto"])
        #expect(controller.currentSession?.events.count == 3)
        #expect(controller.currentSession?.events.allSatisfy { $0.outcome == .approved } == true)

        // 2. 运行中逐项关闭对应选项后，仅未勾选类别保留本人确认并释放弹窗追踪
        controller.updatePreferences { $0.approvePrivacySettings = false }
        #expect(controller.preferences.optionsSummaryText == "已选 2/3")
        controller.updatePreferences { $0.approveCredentialAndAppAuth = false }
        #expect(controller.preferences.optionsSummaryText == "已选 1/3")
        controller.updatePreferences { $0.approveExistingDialogs = false }
        #expect(controller.preferences.optionsSummaryText == "仅常规管理员")
        #expect(persisted.count == 3)

        driver.emitDialog(
            DetectedAuthDialog(
                id: "privacy-manual", source: "隐私与安全", summary: "正在尝试修改你的系统设置",
                category: .privacySettings))
        await settle()
        #expect(controller.currentSession?.events.first?.outcome == .leftForUser)
        #expect(controller.currentSession?.events.first?.detail == "隐私与安全请求由本人确认")

        driver.emitDialog(
            DetectedAuthDialog(
                id: "passkey-manual", source: "Safari", summary: "输入密码以使用通行密钥",
                category: .credentialAndAppAuth))
        await settle()
        #expect(controller.currentSession?.events.first?.outcome == .leftForUser)
        #expect(controller.currentSession?.events.first?.detail == "密码与通行密钥请求由本人确认")

        driver.emitDialog(
            DetectedAuthDialog(
                id: "existing-manual", source: "终端", summary: "终端想要进行更改",
                category: .systemAdmin, isExisting: true))
        await settle()
        #expect(controller.currentSession?.events.first?.outcome == .leftForUser)
        #expect(controller.currentSession?.events.first?.detail == "开启前已存在的请求由本人确认")

        driver.emitDialog(
            DetectedAuthDialog(
                id: "explicit-manual", source: "测试", summary: "仅手动确认弹窗",
                manualConfirmationReason: "显式要求本人确认"))
        await settle()
        #expect(controller.currentSession?.events.first?.outcome == .leftForUser)
        #expect(controller.currentSession?.events.first?.detail == "显式要求本人确认")
        #expect(driver.releasedDialogIDs == ["privacy-manual", "passkey-manual", "existing-manual", "explicit-manual"])

        // 3. 常规系统管理员弹窗仍照常自动批准
        driver.emitDialog(DetectedAuthDialog(id: "new-auth", source: "brew", summary: "brew 想要安装软件"))
        await settle()
        #expect(driver.approvalCalls.last?.id == "new-auth")
        #expect(controller.currentSession?.events.first?.outcome == .approved)
        controller.disable()
    }

    @Test("开启状态下如实记录已批准、受阻与保留本人确认，绝不伪装为已批准")
    func enabledDialogOutcomesRecordedAccurately() async {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock)
        #expect(controller.enable(deadlineChoice: .none))

        let resultsByID: [String: AuthDialogApprovalResult] = [
            "approved": .approved(detail: "已提交授权且弹窗已关闭"),
            "blocked": .blocked(reason: "系统限制自动输入或提交密码，已保留由本人确认"),
            "left": .leftForUser(reason: "未识别到管理员密码输入框，已保留由本人确认"),
        ]
        driver.approveHandler = { id, _ in
            resultsByID[id] ?? .leftForUser(reason: "未知")
        }

        driver.emitDialog(DetectedAuthDialog(id: "approved", source: "zsh", summary: "zsh 想要进行更改"))
        await settle()
        clock.advance(by: 5)
        driver.emitDialog(DetectedAuthDialog(id: "blocked", source: "Installer", summary: "安装器想要安装帮助程序"))
        await settle()
        clock.advance(by: 5)
        driver.emitDialog(
            DetectedAuthDialog(
                id: "left", source: "TouchID", summary: "仅支持触控 ID 验证", isTouchIDOnly: true,
                hasPasswordField: false))
        await settle()

        let events = controller.currentSession?.events ?? []
        #expect(events.count == 3)
        #expect(events[2].outcome == .approved)
        #expect(events[2].detail == "已提交授权且弹窗已关闭")
        #expect(events[1].outcome == .blocked)
        #expect(events[1].outcome != .approved)
        #expect(events[1].detail == "系统限制自动输入或提交密码，已保留由本人确认")
        #expect(events[0].outcome == .leftForUser)
        #expect(events[0].outcome != .approved)
        #expect(events[0].detail == "未识别到管理员密码输入框，已保留由本人确认")
        controller.deactivate()
    }

    @Test("手动关闭后不再介入新弹窗，在途未提交请求不重开或误记批准，已获批操作保留记录")
    func manualDisableStopsFutureDialogsAndHandlesInFlightRequests() async {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock)
        #expect(controller.enable(deadlineChoice: .none))

        // 1. 已完成的获批操作
        driver.defaultApprovalResult = .approved(detail: "已提交授权且弹窗已关闭")
        driver.emitDialog(DetectedAuthDialog(id: "done-1", source: "zsh", summary: "zsh 想要进行更改"))
        await settle()
        #expect(controller.currentSession?.events.count == 1)
        #expect(controller.currentSession?.events.first?.outcome == .approved)

        // 2. 在途未提交/被取消的弹窗请求
        var inFlightContinuation: CheckedContinuation<AuthDialogApprovalResult, Never>?
        driver.approveHandler = { _, _ in
            await withCheckedContinuation { continuation in
                inFlightContinuation = continuation
            }
        }
        driver.emitDialog(DetectedAuthDialog(id: "inflight-cancel", source: "brew", summary: "brew 想要安装软件"))
        for _ in 0..<100 where inFlightContinuation == nil { await Task.yield() }
        #expect(inFlightContinuation != nil)

        // 在途期间手动关闭
        controller.disable(reason: .manual)
        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.history.count == 1)
        #expect(controller.history[0].events.count == 1)
        #expect(controller.history[0].events[0].outcome == .approved)

        // 在途任务返回未提交结果，不得重开模式也不得误记批准
        inFlightContinuation?.resume(returning: .leftForUser(reason: "模式已关闭，未提交授权"))
        inFlightContinuation = nil
        await settle()
        #expect(!controller.isEnabled)
        #expect(controller.history[0].events.count == 1)
        #expect(controller.history[0].events[0].outcome == .approved)

        // 3. 关闭后新到弹窗不再介入
        let callsBefore = driver.approvalCalls.count
        controller.handleDetectedDialog(DetectedAuthDialog(id: "after-off", source: "zsh", summary: "新弹窗"))
        await settle()
        #expect(driver.approvalCalls.count == callsBefore)
        #expect(controller.history[0].events.count == 1)

        // 4. 在关闭前已经完成提交并返回 .approved 的在途请求保留记录且不重开模式
        #expect(controller.enable(deadlineChoice: .none))
        var committedContinuation: CheckedContinuation<AuthDialogApprovalResult, Never>?
        driver.approveHandler = { _, _ in
            await withCheckedContinuation { continuation in
                committedContinuation = continuation
            }
        }
        driver.emitDialog(DetectedAuthDialog(id: "inflight-approved", source: "pkg", summary: "pkg 想要修改设置"))
        for _ in 0..<100 where committedContinuation == nil { await Task.yield() }
        controller.disable(reason: .manual)
        #expect(!controller.isEnabled)
        #expect(controller.history[0].events.isEmpty)

        committedContinuation?.resume(returning: .approved(detail: "已提交授权且弹窗已关闭"))
        await settle()
        #expect(!controller.isEnabled)
        #expect(controller.history[0].events.count == 1)
        #expect(controller.history[0].events[0].outcome == .approved)
    }

    @Test("密码在弹窗触发前或弹窗拒绝复验时失效均自动关闭并提示更新")
    func passwordInvalidationBeforeDialogAndAfterRejection() async {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let verifier = MutablePasswordVerifier(expected: "Pass#1")
        let controller = makeReadyController(
            driver: driver,
            passwordStore: InMemoryUnattendedPasswordStore(initialPassword: "Pass#1"),
            verifier: verifier,
            clock: clock
        )

        // 场景 1：弹窗触发前校验已失效
        #expect(controller.enable(deadlineChoice: .none))
        verifier.setExpected("Pass#2")
        driver.emitDialog(DetectedAuthDialog(id: "pre-invalid", source: "zsh", summary: "zsh 想要进行更改"))
        await settle()

        #expect(driver.approvalCalls.isEmpty)
        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.passwordInvalidated)
        #expect(controller.summaryStatusText == "密码已失效")
        #expect(controller.summaryValueText == "需更新")
        #expect(controller.statusBannerMessage?.contains("更新密码") == true)
        #expect(controller.history.first?.stopReason == .passwordInvalid)
        #expect(controller.history.first?.events.first?.outcome == .passwordInvalid)

        // 场景 2：弹窗返回 .passwordRejected 且复验失效
        #expect(controller.savePassword("Pass#2"))
        #expect(!controller.passwordInvalidated)
        #expect(controller.enable(deadlineChoice: .none))
        driver.approveHandler = { _, _ in
            verifier.setExpected("Pass#3")
            return .passwordRejected(reason: "系统提示密码未通过验证")
        }
        driver.emitDialog(DetectedAuthDialog(id: "rejected-invalid", source: "zsh", summary: "zsh 想要修改设置"))
        await settle()

        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.passwordInvalidated)
        #expect(controller.statusBannerMessage?.contains("更新密码") == true)
        #expect(controller.history.first?.stopReason == .passwordInvalid)
        #expect(controller.history.first?.events.first?.outcome == .passwordInvalid)

        // 场景 3：弹窗返回 .passwordRejected 但本机口令复验仍有效，不误判密码失效也不伪装批准
        #expect(controller.savePassword("Pass#3"))
        #expect(controller.enable(deadlineChoice: .none))
        driver.approveHandler = { _, _ in .passwordRejected(reason: "系统临时拒绝输入") }
        driver.emitDialog(DetectedAuthDialog(id: "rejected-transient", source: "zsh", summary: "zsh 想要继续"))
        await settle()

        #expect(controller.isEnabled)
        #expect(!controller.passwordInvalidated)
        #expect(controller.currentSession?.events.first?.outcome == .blocked)
        controller.deactivate()
    }

    @Test("更换密码即时生效，删除密码立即停止会话且无法再次开启")
    func changePasswordTakesEffectAndDeletePasswordStopsSession() async {
        let driver = FakeUnattendedAuthDriver()
        let passwordStore = InMemoryUnattendedPasswordStore(initialPassword: "OldPass#1")
        let verifier = MutablePasswordVerifier(expected: "OldPass#1")
        let controller = makeReadyController(driver: driver, passwordStore: passwordStore, verifier: verifier)

        #expect(controller.enable(deadlineChoice: .none))
        driver.emitDialog(DetectedAuthDialog(id: "d1", source: "zsh", summary: "第一次授权"))
        await settle()
        #expect(driver.approvalCalls.map(\.password) == ["OldPass#1"])

        // 更换密码即时生效
        verifier.setExpected("NewPass#2")
        #expect(controller.savePassword("NewPass#2"))
        #expect(controller.isEnabled)
        driver.emitDialog(DetectedAuthDialog(id: "d2", source: "zsh", summary: "第二次授权"))
        await settle()
        #expect(driver.approvalCalls.map(\.password) == ["OldPass#1", "NewPass#2"])

        // 删除密码立即关闭当前会话且无法再次开启
        controller.deletePassword()
        #expect(!controller.hasSavedPassword)
        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.history.first?.stopReason == .passwordDeleted)
        #expect(!controller.enable(deadlineChoice: .none))
        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
    }

    @Test("活动记录持久化往返正确，且内存与磁盘 JSON 绝不包含真实密码")
    func historyPersistenceRoundtripAndSecretRedaction() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let historyURL = dir.appending(path: "unattended-auth-history.json")
        let historyStore = UnattendedAuthHistoryStore(url: historyURL)

        let secret = "TopS3cr3t!Admin9482"
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let passwordStore = InMemoryUnattendedPasswordStore(initialPassword: secret)
        let verifier = MutablePasswordVerifier(expected: secret)
        let controller = makeReadyController(
            driver: driver,
            passwordStore: passwordStore,
            verifier: verifier,
            historyStore: historyStore,
            clock: clock
        )

        #expect(controller.enable(deadlineChoice: .durationMinutes(15)))
        clock.advance(by: 30)
        driver.emitDialog(
            DetectedAuthDialog(
                id: "secret-leak-probe",
                source: "zsh \(secret)",
                summary: "zsh 想要进行更改 \(secret) 请输入密码以允许此操作"
            ))
        await settle()
        clock.advance(by: 10)
        controller.disable(reason: .manual)

        #expect(controller.history.count == 1)
        let event = try #require(controller.history[0].events.first)
        #expect(!event.source.contains(secret))
        #expect(!event.summary.contains(secret))
        #expect(!(event.detail ?? "").contains(secret))

        let rawJSON = try String(contentsOf: historyURL, encoding: .utf8)
        #expect(!rawJSON.contains(secret))

        let reloaded = historyStore.load()
        #expect(reloaded == controller.history)

        // 新建控制器加载历史保持往返一致且默认关闭
        let restarted = UnattendedAuthController(
            driver: FakeUnattendedAuthDriver(),
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: historyStore,
            clock: { clock.now() }
        )
        restarted.activate()
        #expect(!restarted.isEnabled)
        #expect(restarted.history == controller.history)
    }

    @Test("模块停用立即停止运行中会话、取消监听并拒绝继续开启")
    func deactivateStopsActiveSessionAndMonitoring() {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock)

        #expect(controller.enable(deadlineChoice: .durationMinutes(20)))
        #expect(controller.isEnabled)
        #expect(driver.isMonitoring)

        controller.deactivate()
        #expect(!controller.isEnabled)
        #expect(controller.deadline == nil)
        #expect(!driver.isMonitoring)
        #expect(driver.stopMonitoringCount == 1)
        #expect(controller.history.first?.stopReason == .pluginDisabled)

        #expect(!controller.enable(deadlineChoice: .none))
        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
    }

    @Test("系统授权宿主识别涵盖 macOS 27.3 实测 Bundle ID 与进程名")
    func systemAuthHostMatchingCoversVerifiedHosts() {
        #expect(
            SystemUnattendedAuthDriver.matchesAuthHost(
                bundleIdentifier: "com.apple.SecurityAgent", processNames: ["SecurityAgent"]))
        #expect(
            SystemUnattendedAuthDriver.matchesAuthHost(
                bundleIdentifier: "com.apple.coreservices.uiagent", processNames: []))
        #expect(
            SystemUnattendedAuthDriver.matchesAuthHost(
                bundleIdentifier: "com.apple.CoreServicesUIAgent", processNames: []))
        #expect(
            SystemUnattendedAuthDriver.matchesAuthHost(
                bundleIdentifier: nil, processNames: ["CoreServicesUIAgent"]))
        #expect(
            SystemUnattendedAuthDriver.matchesAuthHost(
                bundleIdentifier: nil, processNames: ["coreautha"]))
        #expect(
            SystemUnattendedAuthDriver.matchesAuthHost(
                bundleIdentifier: "com.apple.LocalAuthentication.UIAgent", processNames: ["coreautha"]))
        #expect(
            !SystemUnattendedAuthDriver.matchesAuthHost(
                bundleIdentifier: "com.apple.finder", processNames: ["Finder"]))
        #expect(
            SystemUnattendedAuthDriver.matchesEmbeddedAuthService(
                bundleIdentifier: "com.apple.LocalAuthenticationRemoteService", processNames: []))
        #expect(
            SystemUnattendedAuthDriver.matchesEmbeddedAuthService(
                bundleIdentifier: "com.apple.AuthenticationServices.Helper", processNames: []))
        #expect(
            SystemUnattendedAuthDriver.matchesEmbeddedAuthService(
                bundleIdentifier: "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
                processNames: []))
        #expect(
            SystemUnattendedAuthDriver.matchesEmbeddedAuthService(
                bundleIdentifier: "com.apple.AuthKitUI.AKAuthorizationRemoteViewService", processNames: []))
        #expect(
            !SystemUnattendedAuthDriver.matchesEmbeddedAuthService(
                bundleIdentifier: "com.apple.Safari", processNames: ["Safari"]))
        #expect(
            !SystemUnattendedAuthDriver.matchesEmbeddedAuthService(
                bundleIdentifier: "com.citrolabs.ego.lite", processNames: ["ego lite"]))
        #expect(SystemUnattendedAuthDriver.matchesPrivacyAuthHost(bundleIdentifier: "com.apple.systempreferences"))
        #expect(
            SystemUnattendedAuthDriver.matchesPrivacyAuthHost(
                bundleIdentifier: "com.apple.settings.PrivacySecurity.extension"))
        #expect(!SystemUnattendedAuthDriver.matchesPrivacyAuthHost(bundleIdentifier: "com.apple.finder"))
        #expect(!SystemUnattendedAuthDriver.isVerifiedAppleProcess(pid: -1))
        #expect(!SystemUnattendedAuthDriver.isVerifiedAppleProcess(pid: 0))
        #expect(!SystemUnattendedAuthDriver.isVerifiedAppleProcess(pid: getpid()))
    }

    @Test("窗口存在性三态分类对 AX 报错返回未知而不误报已关闭")
    func windowPresenceTriStateClassification() {
        #expect(
            SystemUnattendedAuthDriver.classifyWindowPresence(
                processTerminated: true,
                windowsError: .cannotComplete,
                matchesWindowsOrSheets: false,
                focusedError: .cannotComplete,
                matchesFocused: false,
                mainError: .cannotComplete,
                matchesMain: false) == .absent)
        #expect(
            SystemUnattendedAuthDriver.classifyWindowPresence(
                processTerminated: false,
                windowsError: .success,
                matchesWindowsOrSheets: true,
                focusedError: .noValue,
                matchesFocused: false,
                mainError: .noValue,
                matchesMain: false) == .present)
        #expect(
            SystemUnattendedAuthDriver.classifyWindowPresence(
                processTerminated: false,
                windowsError: .success,
                matchesWindowsOrSheets: false,
                focusedError: .noValue,
                matchesFocused: false,
                mainError: .attributeUnsupported,
                matchesMain: false) == .absent)
        #expect(
            SystemUnattendedAuthDriver.classifyWindowPresence(
                processTerminated: false,
                windowsError: .apiDisabled,
                matchesWindowsOrSheets: false,
                focusedError: .noValue,
                matchesFocused: false,
                mainError: .noValue,
                matchesMain: false) == .unknown)
        #expect(
            SystemUnattendedAuthDriver.classifyWindowPresence(
                processTerminated: false,
                windowsError: .success,
                matchesWindowsOrSheets: false,
                focusedError: .cannotComplete,
                matchesFocused: false,
                mainError: .noValue,
                matchesMain: false) == .unknown)
    }

    @Test("在途批准返回时若已越过截止时间则立即停用且不再写入当前会话")
    func inFlightApprovalCrossingDeadlineStopsCleanly() async {
        let clock = MutableTestClock(Self.baseDate)
        let driver = FakeUnattendedAuthDriver()
        let controller = makeReadyController(driver: driver, clock: clock)
        #expect(controller.enable(deadlineChoice: .durationMinutes(5)))

        var continuation: CheckedContinuation<AuthDialogApprovalResult, Never>?
        driver.approveHandler = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        driver.emitDialog(DetectedAuthDialog(id: "cross-deadline", source: "zsh", summary: "zsh 想要进行更改"))
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        #expect(continuation != nil)

        clock.advance(by: 6 * 60)
        continuation?.resume(returning: .blocked(reason: "超时未提交"))
        continuation = nil
        await settle()

        #expect(!controller.isEnabled)
        #expect(!driver.isMonitoring)
        #expect(controller.history.first?.stopReason == .deadlineReached)
        #expect(controller.history.first?.events.isEmpty == true)
    }

    @Test("密码错误文本识别涵盖中英文无效密码提示")
    func passwordRejectedTextMatchesEnglishInvalidPrompt() {
        #expect(SystemUnattendedAuthDriver.isPasswordRejectedText("对不起，你输入了无效的密码。"))
        #expect(SystemUnattendedAuthDriver.isPasswordRejectedText("Sorry, you entered an invalid password."))
        #expect(SystemUnattendedAuthDriver.isPasswordRejectedText("Password is incorrect, try again."))
        #expect(!SystemUnattendedAuthDriver.isPasswordRejectedText("请输入密码以允许此操作。"))
    }

    private func makeReadyController(
        driver: FakeUnattendedAuthDriver,
        passwordStore: InMemoryUnattendedPasswordStore = InMemoryUnattendedPasswordStore(initialPassword: "Admin#2026"),
        verifier: MutablePasswordVerifier = MutablePasswordVerifier(expected: "Admin#2026"),
        historyStore: UnattendedAuthHistoryStore = .inMemory,
        clock: MutableTestClock = MutableTestClock(baseDate),
        sleeper: TestSleeper? = nil
    ) -> UnattendedAuthController {
        let sleepClosure: @Sendable (Duration) async throws -> Void =
            if let sleeper {
                { try await sleeper.sleep($0) }
            } else {
                { try await Task.sleep(for: $0) }
            }
        let controller = UnattendedAuthController(
            driver: driver,
            passwordStore: passwordStore,
            passwordVerifier: verifier,
            historyStore: historyStore,
            clock: { clock.now() },
            sleep: sleepClosure
        )
        controller.activate()
        return controller
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

private final class MutableTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ initial: Date) {
        self.current = initial
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

private final class TestSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    continuations[id] = continuation
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = lock.withLock { continuations.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    @MainActor
    func tick() async {
        for _ in 0..<200 {
            if lock.withLock({ !continuations.isEmpty }) { break }
            await Task.yield()
        }
        let pending = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in pending {
            continuation.resume()
        }
        for _ in 0..<50 { await Task.yield() }
    }
}

private final class MutablePasswordVerifier: UnattendedAuthPasswordVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var expected: String?
    private var unavailableReason: String?

    init(expected: String? = nil, unavailableReason: String? = nil) {
        self.expected = expected
        self.unavailableReason = unavailableReason
    }

    func setExpected(_ value: String?) {
        lock.withLock {
            expected = value
            unavailableReason = nil
        }
    }

    func setUnavailable(_ reason: String) {
        lock.withLock { unavailableReason = reason }
    }

    func verifyPassword(_ password: String) -> UnattendedAuthPasswordVerification {
        lock.withLock {
            if let unavailableReason { return .unavailable(unavailableReason) }
            guard !password.isEmpty else { return .invalid }
            guard let expected else { return .valid }
            return password == expected ? .valid : .invalid
        }
    }
}

@MainActor
private final class FakeUnattendedAuthDriver: UnattendedAuthSystemDriver {
    struct ApprovalCall: Equatable {
        let id: String
        let password: String
    }

    let isPreview = false
    var trusted = true
    var locked = false
    var isMonitoring = false
    var startMonitoringCount = 0
    var stopMonitoringCount = 0
    var existingDialogChecks = 0
    var existingDialogs: [DetectedAuthDialog] = []
    var approvalCalls: [ApprovalCall] = []
    var releasedDialogIDs: [String] = []

    private var onDialog: (@MainActor (DetectedAuthDialog) -> Void)?
    private var onScreenLockChanged: (@MainActor (Bool) -> Void)?
    private var onWake: (@MainActor () -> Void)?

    var approveHandler: (@MainActor (String, String) async -> AuthDialogApprovalResult)?
    var defaultApprovalResult: AuthDialogApprovalResult = .approved(detail: "已提交授权且弹窗已关闭")

    func isAccessibilityTrusted() -> Bool { trusted }
    func requestAccessibilityTrust() { trusted = true }
    func openAccessibilitySettings() {}
    func isScreenCurrentlyLocked() -> Bool { locked }

    func startMonitoring(
        onDialog: @escaping @MainActor (DetectedAuthDialog) -> Void,
        onScreenLockChanged: @escaping @MainActor (Bool) -> Void,
        onWake: @escaping @MainActor () -> Void
    ) throws {
        isMonitoring = true
        startMonitoringCount += 1
        self.onDialog = onDialog
        self.onScreenLockChanged = onScreenLockChanged
        self.onWake = onWake
    }

    func checkExistingDialogs() {
        existingDialogChecks += 1
        for dialog in existingDialogs { onDialog?(dialog) }
    }

    func stopMonitoring() {
        isMonitoring = false
        stopMonitoringCount += 1
        onDialog = nil
        onScreenLockChanged = nil
        onWake = nil
    }

    func releaseDialog(id: String) {
        releasedDialogIDs.append(id)
    }

    func approveDialog(id: String, password: String) async -> AuthDialogApprovalResult {
        approvalCalls.append(ApprovalCall(id: id, password: password))
        if let approveHandler {
            return await approveHandler(id, password)
        }
        return defaultApprovalResult
    }

    func emitDialog(_ dialog: DetectedAuthDialog) {
        onDialog?(dialog)
    }

    func emitScreenLockChanged(_ newLocked: Bool) {
        locked = newLocked
        onScreenLockChanged?(newLocked)
    }

    func emitWake() {
        onWake?()
    }
}
