// [INPUT]: Sparkle 用户交互事件、阶段截止时间与单次重试入口。
// [OUTPUT]: 同一紧凑窗口中的确认 / 取消 / 明确失败与重试，旧会话回调失效。
// [POS]: 更新交互与截止时间；feed / 安装包双重验签及安装仍由 Sparkle 执行。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Sparkle
import VorsmateCore

@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    let panel: UpdatePanelController
    private(set) var active = false
    private(set) var stage = UpdateStage.finished
    var changed: ((UpdateStage) -> Void)?
    var retry: (() -> Void)?
    private let timeouts: UpdateTimeouts
    private let showsWindows: Bool
    private let pause: (Duration) async throws -> Void
    private var manual = false
    private var cancellation: (() -> Void)?
    private var deadline: Task<Void, Never>?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    init(
        panel: UpdatePanelController = UpdatePanelController(), timeouts: UpdateTimeouts = UpdateTimeouts(),
        showsWindows: Bool = true,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.panel = panel
        self.timeouts = timeouts
        self.showsWindows = showsWindows
        self.pause = pause
    }
    func begin(manual: Bool) {
        self.manual = manual
        active = true
        transition(.checking)
        arm(timeouts.checking)
        checking()
    }
    func focus() {
        manual = true
        if stage == .checking { checking() } else { showPanel() }
    }
    func stop() {
        deadline?.cancel()
        if stage != .installing && stage != .ready { cancel() }
    }
    private func transition(_ stage: UpdateStage) {
        deadline?.cancel()
        deadline = nil
        self.stage = stage
        changed?(stage)
    }
    private func arm(_ duration: Duration) {
        deadline?.cancel()
        let watchedStage = stage
        let pause = pause
        deadline = Task { [weak self] in
            do {
                try await pause(duration)
                try Task.checkCancellation()
            } catch { return }
            guard let self, active, stage == watchedStage else { return }
            fail(.timedOut(watchedStage))
        }
    }
    private func showPanel() { if showsWindows { panel.show() } }
    private func checking() {
        guard manual else { return }
        panel.model.present(
            "正在检查更新…", detail: "", busy: true, secondary: "取消",
            cancel: { [weak self] in self?.cancel() })
        showPanel()
    }
    func cancel() {
        guard active else { return }
        active = false
        transition(.finished)
        let cancel = cancellation
        cancellation = nil
        cancel?()
        panel.hide()
    }
    func fail(_ failure: UpdateFailure, acknowledgement: (() -> Void)? = nil) {
        guard active else {
            acknowledgement?()
            return
        }
        active = false
        transition(.finished)
        let cancel = cancellation
        cancellation = nil
        if acknowledgement == nil { cancel?() }
        // Sparkle 的会话先结束，再呈现错误；“重试”不必等用户关闭旧错误才能生效。
        acknowledgement?()
        guard manual else { return }
        panel.model.present(
            failure.title, detail: failure.detail, primary: "重试",
            action: { [weak self] in
                self?.panel.hide()
                self?.retry?()
            }, secondary: "关闭", cancel: { [weak self] in self?.panel.hide() })
        showPanel()
    }
    private func message(_ title: String, detail: String) {
        panel.model.present(
            title, detail: detail, primary: "好", action: { [weak self] in self?.panel.hide() })
        showPanel()
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard active else {
            cancellation()
            return
        }
        self.cancellation = cancellation
        checking()
    }
    func showUpdateFound(
        with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard active else {
            reply(.skip)
            return
        }
        manual = true
        cancellation = nil
        transition(.offered)
        if item.isInformationOnlyUpdate {
            panel.model.present(
                "发现新版本", detail: item.displayVersionString, primary: "前往发布页",
                action: { [weak self] in
                    self?.active = false
                    self?.transition(.finished)
                    self?.panel.hide()
                    NSWorkspace.shared.open(UpdatePolicy.releaseURL)
                    reply(.dismiss)
                }, secondary: "稍后",
                cancel: { [weak self] in
                    self?.active = false
                    self?.transition(.finished)
                    self?.panel.hide()
                    reply(.dismiss)
                })
        } else {
            panel.model.present(
                "新版本已就绪",
                detail:
                    "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") → \(item.displayVersionString)",
                primary: state.stage == .installing ? "重启更新" : "更新",
                action: { [weak self] in
                    guard let self, active else { return }
                    transition(.downloading)
                    arm(timeouts.downloading)
                    reply(.install)
                }, secondary: "稍后",
                cancel: { [weak self] in
                    self?.active = false
                    self?.transition(.finished)
                    self?.panel.hide()
                    reply(.dismiss)
                })
        }
        showPanel()
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard active else {
            acknowledgement()
            return
        }
        active = false
        cancellation = nil
        transition(.finished)
        acknowledgement()
        guard manual else { return }
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        if [3, 4, 5].contains(reason ?? -1) {
            message("此更新暂不支持当前系统", detail: "请从官方发布页查看系统与机型要求。")
        } else {
            message(
                "已是最新版本",
                detail:
                    "当前版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")。")
        }
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        var failure = UpdateFailure(error)
        if case .timedOut = failure { failure = .timedOut(stage) }
        fail(failure, acknowledgement: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard active else {
            cancellation()
            return
        }
        self.cancellation = cancellation
        expected = 0
        received = 0
        transition(.downloading)
        arm(timeouts.downloading)
        panel.model.present(
            "正在下载更新…", detail: "", busy: true, secondary: "取消",
            cancel: { [weak self] in self?.cancel() })
        showPanel()
    }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {
        guard active, stage == .downloading else { return }
        expected = length
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard active, stage == .downloading, length > 0 else { return }
        received = received.addingReportingOverflow(length).overflow ? UInt64.max : received + length
        if expected > 0 { panel.model.progress = min(1, Double(received) / Double(expected)) }
        arm(timeouts.downloading)
    }
    func showDownloadDidStartExtractingUpdate() {
        guard active else { return }
        cancellation = nil
        transition(.preparing)
        arm(timeouts.preparing)
        panel.model.present("正在准备更新…", detail: "", busy: true)
        showPanel()
    }
    func showExtractionReceivedProgress(_ progress: Double) {
        guard active, stage == .preparing, progress.isFinite else { return }
        panel.model.progress = min(1, max(0, progress))
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // 已过期的准备操作不能在用户重试后重新提出安装，更不能留到退出时悄悄安装。
        guard active else {
            reply(.skip)
            return
        }
        transition(.ready)
        panel.model.present(
            "可以更新了", detail: "重启后继续使用现有设置。", primary: "重启更新",
            action: { reply(.install) }, secondary: "稍后",
            cancel: { [weak self] in
                self?.panel.hide()
                reply(.dismiss)
            })
        showPanel()
    }
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
    ) {
        guard active else { return }
        transition(.installing)
        panel.model.present("正在安装更新…", detail: "", busy: true)
        showPanel()
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        guard active else {
            acknowledgement()
            return
        }
        active = false
        transition(.finished)
        acknowledgement()
        message("更新完成", detail: "")
    }
    func dismissUpdateInstallation() { if active { panel.hide() } }
    func showUpdateInFocus() { if active { focus() } }
}
