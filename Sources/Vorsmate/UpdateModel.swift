// [INPUT]: 官方 GitHub Releases、Sparkle、包内更新公钥；不读取或改写设备配置。
// [OUTPUT]: 后台更新检查、单一菜单入口与原生下载 / 安装 / 重启流程。
// [POS]: 应用级更新装配；更新前沿用正常退出恢复，助手授权不注销。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import Sparkle
import SwiftUI
import VorsmateCore

@MainActor
final class UpdateModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var checking = false
    @Published private(set) var canCheck = true
    private let enabled: Bool
    private let session: URLSession
    private let version: String
    private var schedule: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var candidate: GitHubUpdate?
    private var observation: AnyCancellable?
    private var started = false
    private let driver = UpdateUserDriver()
    private lazy var updater = SPUUpdater(
        hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)

    init(enabled: Bool) {
        self.enabled = enabled
        self.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
        super.init()
        guard enabled else { return }
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
        guard !checking, canCheck, enabled else { return }
        checking = true
        if manual { driver.checking { [weak self] in self?.checkTask?.cancel() } }
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                checking = false
                checkTask = nil
            }
            do {
                var request = URLRequest(url: GitHubUpdate.releasesURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("Vorsmate/\(version)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                candidate = try GitHubUpdate.latest(in: data, newerThan: version)
                guard let candidate else {
                    if manual { show(message: "已是最新版本", detail: "当前版本 \(version)。") }
                    return
                }
                guard candidate.feedURL != nil else {
                    if manual {
                        show(
                            message: "发现新版本 \(candidate.version)", detail: "此版本尚未提供应用内更新包，可从发布页下载安装。",
                            release: candidate.releaseURL)
                    }
                    return
                }
                if !started {
                    try updater.start()
                    started = true
                    observation = updater.publisher(for: \.canCheckForUpdates)
                        .sink { [weak self] value in self?.canCheck = value }
                }
                if manual { updater.checkForUpdates() } else { updater.checkForUpdatesInBackground() }
            } catch is CancellationError {
            } catch {
                if manual && !Task.isCancelled { show(message: "暂时无法检查更新", detail: "请检查网络连接后重试。") }
            }
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { candidate?.feedURL?.absoluteString }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck)
        throws
    {
        guard let candidate, updateItem.fileURL == candidate.downloadURL,
            updateItem.displayVersionString == candidate.version
        else {
            throw NSError(
                domain: "Vorsmate.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "更新包与 GitHub 发布版本不一致。"])
        }
    }

    func stop() {
        schedule?.cancel()
        schedule = nil
        checkTask?.cancel()
        checkTask = nil
        session.invalidateAndCancel()
    }

    private func show(message: String, detail: String, release: URL? = nil) {
        driver.message(message, detail: detail, button: release == nil ? "好" : "前往发布页") {
            if let release { NSWorkspace.shared.open(release) }
        }
    }
}

struct UpdateMenuItem: View {
    @ObservedObject var model: UpdateModel
    var body: some View {
        Button(model.checking ? "正在检查更新…" : "检查更新…") { model.check() }
            .disabled(model.checking || !model.canCheck)
    }
}
