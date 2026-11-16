// [INPUT]: 固定签名 feed、Sparkle 更新会话和主线程检查入口。
// [OUTPUT]: 定时 / 手动检查、可取消且有截止时间的独立会话与安全重试。
// [POS]: 更新装配；不调用 GitHub API，不读取或改写设备配置及助手授权。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import Foundation
import Sparkle
import SwiftUI
import VorsmateCore

@MainActor
protocol UpdateSession: AnyObject {
    func start() throws
}

@MainActor
final class SparkleUpdateSession: NSObject, UpdateSession, SPUUpdaterDelegate {
    private let driver: UpdateUserDriver
    private let feedURL: URL
    private lazy var updater = SPUUpdater(
        hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)

    init(driver: UpdateUserDriver, feedURL: URL = UpdatePolicy.feedURL) {
        self.driver = driver
        self.feedURL = feedURL
    }
    func start() throws {
        try updater.start()
        // 统一由本项目安排检查；后台仅隐藏检查 / 无更新 / 失败反馈，不绕过用户确认。
        updater.checkForUpdates()
    }
    func feedURLString(for updater: SPUUpdater) -> String? { feedURL.absoluteString }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if !driver.active { throw URLError(.cancelled) }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck)
        throws
    {
        guard driver.active else { throw URLError(.cancelled) }
        guard
            item.isInformationOnlyUpdate
                || UpdatePolicy.accepts(downloadURL: item.fileURL, version: item.displayVersionString)
        else { throw UpdateFailure.untrustedSource }
    }
}

@MainActor
final class UpdateModel: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var canCheck = true
    let panel = UpdatePanelController()
    private let enabled: Bool
    private let timeouts: UpdateTimeouts
    private let showsWindows: Bool
    private let pause: (Duration) async throws -> Void
    private let makeSession: @MainActor (UpdateUserDriver) -> any UpdateSession
    private var schedule: Task<Void, Never>?
    private var session: (any UpdateSession)?
    private var driver: UpdateUserDriver?
    private var attempt = UUID()

    init(
        enabled: Bool, scheduled: Bool = true, timeouts: UpdateTimeouts = UpdateTimeouts(), showsWindows: Bool = true,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        makeSession: @escaping @MainActor (UpdateUserDriver) -> any UpdateSession = { SparkleUpdateSession(driver: $0) }
    ) {
        self.enabled = enabled
        self.timeouts = timeouts
        self.showsWindows = showsWindows
        self.pause = pause
        self.makeSession = makeSession
        guard enabled, scheduled else { return }
        schedule = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(60))
                while !Task.isCancelled {
                    self?.check(manual: false)
                    try await Task.sleep(for: .seconds(12 * 60 * 60))
                }
            } catch {}
        }
    }
    func check(manual: Bool = true) {
        guard enabled else { return }
        if let driver, driver.active {
            if manual { driver.focus() }
            return
        }
        let id = UUID()
        attempt = id
        let driver = UpdateUserDriver(panel: panel, timeouts: timeouts, showsWindows: showsWindows, pause: pause)
        driver.changed = { [weak self] stage in
            guard let self, attempt == id else { return }
            checking = stage == .checking
            canCheck = ![.checking, .downloading, .preparing, .installing].contains(stage)
        }
        driver.retry = { [weak self] in self?.check() }
        self.driver = driver
        // 截止时间覆盖 Sparkle 开始回调前的助手探测；失效会话不能覆盖下一次检查。
        driver.begin(manual: manual)
        let session = makeSession(driver)
        self.session = session
        do { try session.start() } catch { driver.fail(UpdateFailure(error)) }
    }
    func stop() {
        schedule?.cancel()
        schedule = nil
        driver?.stop()
    }
}

struct UpdateMenuItem: View {
    @ObservedObject var model: UpdateModel
    var body: some View {
        Button(model.checking ? "正在检查更新…" : "检查更新…") { model.check() }
            .disabled(model.checking || !model.canCheck)
    }
}
