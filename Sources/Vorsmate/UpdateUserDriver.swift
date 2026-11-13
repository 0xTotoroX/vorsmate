// [INPUT]: Sparkle 用户交互协议的检查、下载、解包及安装事件。
// [OUTPUT]: 同一紧凑更新窗口中的状态与一次性确认 / 取消回调。
// [POS]: 只替换 Sparkle 交互层；签名验证、安装与重启继续由框架负责。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Sparkle

@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    let panel = UpdatePanelController()
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    func message(_ title: String, detail: String, button: String = "好", action: (() -> Void)? = nil) {
        panel.model.present(
            title, detail: detail, primary: button,
            action: { [weak self] in
                self?.panel.hide()
                action?()
            })
        panel.show()
    }
    func checking(cancel: @escaping () -> Void) {
        panel.model.present(
            "正在检查更新…", detail: "", busy: true, secondary: "取消",
            cancel: { [weak self] in
                self?.panel.hide()
                cancel()
            })
        panel.show()
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { checking(cancel: cancellation) }
    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if appcastItem.isInformationOnlyUpdate {
            panel.model.present(
                "发现新版本", detail: appcastItem.displayVersionString, primary: "前往发布页",
                action: {
                    if let url = appcastItem.infoURL { NSWorkspace.shared.open(url) }
                    reply(.dismiss)
                }, secondary: "稍后", cancel: { reply(.dismiss) })
        } else {
            panel.model.present(
                "新版本已就绪",
                detail:
                    "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") → \(appcastItem.displayVersionString)",
                primary: state.stage == .installing ? "重启更新" : "更新", action: { reply(.install) }, secondary: "稍后",
                cancel: { reply(.dismiss) })
        }
        panel.show()
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        message("没有可安装的新版本", detail: error.localizedDescription, action: acknowledgement)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        message("更新未完成", detail: error.localizedDescription, action: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0
        received = 0
        panel.model.present("正在下载更新…", detail: "", busy: true, secondary: "取消", cancel: cancellation)
        panel.show()
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received = received.addingReportingOverflow(length).overflow ? UInt64.max : received + length
        if expected > 0 { panel.model.progress = min(1, Double(received) / Double(expected)) }
    }
    func showDownloadDidStartExtractingUpdate() {
        panel.model.present("正在准备更新…", detail: "", busy: true)
        panel.show()
    }
    func showExtractionReceivedProgress(_ progress: Double) {
        if progress.isFinite { panel.model.progress = min(1, max(0, progress)) }
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        panel.model.present(
            "可以更新了", detail: "重启后继续使用现有设置。", primary: "重启更新", action: { reply(.install) }, secondary: "稍后",
            cancel: { reply(.dismiss) })
        panel.show()
    }
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
    ) {
        panel.model.present("正在安装更新…", detail: "", busy: true)
        panel.show()
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        message("更新完成", detail: "", action: acknowledgement)
    }
    func dismissUpdateInstallation() { panel.hide() }
    func showUpdateInFocus() { panel.show() }
}
