// [INPUT]: 面板生命周期、用户触发的收藏和可替换的封面服务。
// [OUTPUT]: 工具页内的收藏入口及进行中、成功、有重复或失败状态。
// [POS]: 独立的收藏封面模块，启用和展开都不会访问 Music 或 Eagle。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore
import VorsmateSystem

@MainActor
final class CoverArchiveModel: ObservableObject, VorsmatePlugin {
    let id = PluginID.coverArchive
    @Published private(set) var phase = Phase.idle
    private let archive: @Sendable () async throws -> MusicCoverResult
    private var active = false

    enum Phase: Equatable {
        case idle
        case saving
        case saved(String)
        case duplicate(String)
        case failed(String)

        var status: String {
            switch self {
            case .idle: "Apple Music → Eagle"
            case .saving: "正在收藏"
            case .saved: "已收藏"
            case .duplicate: "封面已存在"
            case .failed: "收藏失败"
            }
        }

        var indicator: PanelPluginIndicator {
            switch self {
            case .saving: .active
            case .failed: .error
            default: .none
            }
        }
    }

    init(archive: @escaping @Sendable () async throws -> MusicCoverResult) {
        self.archive = archive
    }

    convenience init(preview: Bool) {
        if preview {
            self.init { .archived("示例歌曲 - 示例歌手") }
        } else {
            let service = MusicCoverArchive()
            self.init { try await service.archive() }
        }
    }

    var registration: PanelPluginRegistration {
        PanelPluginRegistration(
            plugin: self, changes: objectWillChange, indicator: { self.phase.indicator },
            row: { CoverArchiveSection(model: self, expanded: $0.expanded) })
    }

    func activate() { active = true }
    func deactivate() { active = false }
    func refresh() {}
    func panelDidChangeVisibility(_ visible: Bool) {}

    func save() {
        guard active, phase != .saving else { return }
        phase = .saving
        Task { [weak self, archive] in
            let result: Phase
            do {
                switch try await archive() {
                case .archived(let name), .preview(let name): result = .saved(name)
                case .duplicate(let name): result = .duplicate(name)
                }
            } catch {
                result = .failed((error as? MusicCoverError ?? .musicReadFailed).localizedDescription)
            }
            self?.phase = result
        }
    }
}

struct CoverArchiveSection: View {
    @ObservedObject var model: CoverArchiveModel
    @Binding var expanded: Bool
    @Environment(\.panelRowHorizontalPadding) private var horizontalPadding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: model.id.title, symbol: model.id.symbol, status: model.phase.status,
                    statusColor: model.phase.indicator == .error ? .red : .secondary, value: "",
                    navigation: .disclosure(expanded: expanded), pending: model.phase == .saving)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.id.title)
            .accessibilityValue("\(model.phase.status)，\(expanded ? "已展开" : "已收起")")
            .accessibilityIdentifier("coverArchive.expand")

            if expanded {
                PanelInlineCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("收藏当前封面") { model.save() }
                            .disabled(model.phase == .saving)
                            .accessibilityIdentifier("coverArchive.save")

                        switch model.phase {
                        case .saved(let name), .duplicate(let name):
                            Text(name).font(.callout).foregroundStyle(.secondary)
                        case .failed(let message):
                            PanelInlineNotice(text: message, isError: true)
                        case .idle, .saving:
                            EmptyView()
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
