// [INPUT]: 本机网盘连接器、面板生命周期及可替换的 Finder／浏览器入口。
// [OUTPUT]: 查看挂载状态，按需开启、关闭或打开网盘界面。
// [POS]: 用户发起的后台工作完成后回读状态；关闭面板不会中断在途操作。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import SwiftUI
import VorsmateCore
import VorsmateSystem

@MainActor
final class OpenListModel: ObservableObject, VorsmatePlugin {
    enum Action {
        case refresh, start, stop, web

        var progress: String {
            switch self {
            case .refresh: "正在读取状态"
            case .start: "正在开启"
            case .stop: "正在关闭"
            case .web: "正在打开网盘界面"
            }
        }
    }

    let id = PluginID.openList
    @Published private(set) var status: OpenListStatus?
    @Published private(set) var pending: Action?
    @Published private(set) var error: OpenListError?
    @Published private(set) var feedback: String?
    private let client: any OpenListClientProtocol
    private let showURL: (URL) -> Bool
    private let openMounts: () -> Bool
    private let openConfiguration: () -> Void
    private var active = false

    init(
        client: any OpenListClientProtocol, showURL: @escaping (URL) -> Bool,
        openMounts: @escaping () -> Bool, openConfiguration: @escaping () -> Void
    ) {
        self.client = client
        self.showURL = showURL
        self.openMounts = openMounts
        self.openConfiguration = openConfiguration
    }

    convenience init(client: any OpenListClientProtocol = OpenListClient()) {
        self.init(
            client: client, showURL: { NSWorkspace.shared.open($0) },
            openMounts: {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let entry = home.appending(path: "网盘")
                let folder =
                    FileManager.default.fileExists(atPath: entry.path)
                    ? entry : home.appending(path: "OpenListMounts")
                return NSWorkspace.shared.open(folder)
            },
            openConfiguration: {
                let folder = OpenListClient.connectorDirectory
                do {
                    try FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    _ = NSWorkspace.shared.open(folder)
                } catch {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.deletingLastPathComponent()])
                }
            })
    }

    static func preview() -> OpenListModel {
        OpenListModel(
            client: PreviewOpenListClient(), showURL: { _ in true }, openMounts: { true }, openConfiguration: {})
    }

    var registration: PanelPluginRegistration {
        PanelPluginRegistration(
            plugin: self, changes: objectWillChange, indicator: { self.indicator },
            row: { OpenListSection(model: self, expanded: $0.expanded) })
    }

    var indicator: PanelPluginIndicator {
        if let pending, pending != .refresh { return .active }
        return error == nil || error == .missingConnector ? .none : .error
    }

    var summary: String {
        if let pending { return pending.progress }
        if error == .missingConnector { return "未配置" }
        if let error { return status == nil || error == .unavailable ? "暂不可用" : "操作未完成" }
        guard let status else { return "按需开启" }
        if status.mounted > 0 { return "已挂载" }
        return status.connectionLoaded ? "连接已开启" : "已关闭"
    }

    func activate() { active = true }
    func deactivate() { active = false }
    func refresh() { perform(.refresh) }
    func panelDidChangeVisibility(_ visible: Bool) {
        if visible { refresh() }
    }

    func settings() { openConfiguration() }

    func perform(_ action: Action) {
        guard active, pending == nil else { return }
        pending = action
        if action != .refresh { feedback = nil }
        error = nil
        Task { [weak self] in
            guard let self else { return }
            defer { pending = nil }
            do {
                switch action {
                case .refresh: status = try await client.status()
                case .start:
                    try await client.start()
                    feedback = openMounts() ? "网盘已开启。" : "网盘已开启，请在 Finder 中打开。"
                case .stop:
                    try await client.stop()
                    feedback = "网盘和专用连接已关闭。"
                case .web:
                    let url = try await client.webInterface()
                    guard showURL(url) else { throw OpenListError.operationRejected("无法打开网盘界面。") }
                    feedback = "已打开网盘界面。"
                }
            } catch {
                self.error = error as? OpenListError ?? .unavailable
                if action == .refresh { status = nil }
            }
            if action != .refresh { status = try? await client.status() }
        }
    }
}

private actor PreviewOpenListClient: OpenListClientProtocol {
    private var mounted = false
    private var connected = false

    func status() -> OpenListStatus {
        OpenListStatus(mounted: mounted ? 4 : 0, total: 4, connectionLoaded: connected)
    }
    func start() {
        mounted = true
        connected = true
    }
    func stop() {
        mounted = false
        connected = false
    }
    func webInterface() -> URL {
        connected = true
        return URL(string: "http://127.0.0.1:5580/login")!
    }
}

struct OpenListSection: View {
    @ObservedObject var model: OpenListModel
    @Binding var expanded: Bool
    @Environment(\.panelRowHorizontalPadding) private var horizontalPadding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: model.id.title, symbol: model.id.symbol, status: model.summary,
                    statusColor: model.indicator == .error ? .red : .secondary,
                    value: model.status.map { "\($0.mounted) / \($0.total) 卷" } ?? "",
                    navigation: .disclosure(expanded: expanded), pending: model.pending != nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.id.title)
            .accessibilityValue("\(model.summary)，\(expanded ? "已展开" : "已收起")")
            .accessibilityIdentifier("openList.expand")

            if expanded {
                PanelInlineCard {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.error == .missingConnector {
                            Button("打开配置目录") { model.settings() }
                                .accessibilityIdentifier("openList.settings")
                        } else {
                            HStack(spacing: 8) {
                                Button("开启网盘") { model.perform(.start) }
                                    .accessibilityIdentifier("openList.start")
                                Button("关闭网盘") { model.perform(.stop) }
                                    .accessibilityIdentifier("openList.stop")
                                Button("网盘界面") { model.perform(.web) }
                                    .accessibilityIdentifier("openList.web")
                            }
                            .disabled(model.pending != nil)
                        }
                        if let error = model.error {
                            PanelInlineNotice(text: error.localizedDescription, isError: model.indicator == .error)
                        } else if let feedback = model.feedback {
                            Text(feedback).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 12)
            }
        }
    }
}
