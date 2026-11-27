// [INPUT]: TasksModel、PanelSummaryRow、面板最大高度与交互保护回调。
// [OUTPUT]: 总览「待办」摘要行与同宽详情页（项目内新增、标题原位编辑和独立的勾选按钮）。
// [POS]: PanelView 内可选「待办」子视图；遵循 DESIGN.md 同宽详情导航与 0.5 秒离开保护约定。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore

struct TasksSummaryRow: View {
    @ObservedObject var model: TasksModel
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            PanelSummaryRow(
                title: PluginID.tasks.title,
                symbol: PluginID.tasks.symbol,
                status: model.summaryStatus,
                value: model.summaryValue ?? "",
                navigation: .detail,
                pending: model.loading && model.connectionState == .connecting
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tasks.summary")
        .accessibilityLabel(PluginID.tasks.title)
        .accessibilityValue(model.overviewAccessibilityValue)
    }
}

struct TasksDetailView: View {
    @ObservedObject var model: TasksModel
    let maximumHeight: CGFloat
    var protectInteraction: (Bool) -> Void = { _ in }
    let back: () -> Void

    private enum Target: Hashable {
        case list(String)
        case item(String)
    }
    private struct Draft {
        var text: String
        var original: ReminderItem?
        var notice: String?
    }

    @State private var drafts: [Target: Draft] = [:]
    @State private var headerHeight: CGFloat = 90
    @State private var bodyHeight: CGFloat = 180
    @FocusState private var focused: Target?

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    ceil($0.size.height)
                } action: {
                    headerHeight = $0
                }

            ScrollView {
                scrollContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .onGeometryChange(for: CGFloat.self) {
                        ceil($0.size.height)
                    } action: {
                        bodyHeight = $0
                    }
            }
            .scrollIndicators(.never)
            .frame(height: min(bodyHeight, max(64, maximumHeight - headerHeight)))
        }
        .onChange(of: focused) { _, target in
            protectInteraction(target != nil)
        }
        .onDisappear {
            focused = nil
            protectInteraction(false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: back) {
                    Label("Vorsmate", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tasks.back")

                HStack(spacing: 8) {
                    Text(PluginID.tasks.title)
                        .font(.title2.weight(.semibold))
                    Spacer(minLength: 8)
                    if model.connectionState == .connected {
                        Text("\(model.projection.totalIncompleteCount) 项未完成")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if model.loading {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            if let error = model.actionError, model.connectionState == .connected {
                PanelInlineNotice(text: error, symbol: "exclamationmark.triangle.fill", isError: true)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("tasks.error")
            }
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var scrollContent: some View {
        if model.connectionState == .offline || model.connectionState == .readFailed {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.actionError ?? "打开提醒事项连接器，允许读取这台 Mac 的待办。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("打开连接器") { model.openConnector() }
                    Button("重试") { model.refresh() }
                        .accessibilityIdentifier("tasks.reconnect")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 6)
        } else if model.connectionState == .connecting && model.projection.buckets.isEmpty {
            Text("正在读取待办…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.projection.projectLists.isEmpty {
            Text("暂无项目列表")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            let buckets = Dictionary(uniqueKeysWithValues: model.projection.buckets.map { ($0.list.id, $0.items) })
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.projection.projectLists) { list in
                    let target = Target.list(list.id)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(list.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            Button {
                                begin(target)
                            } label: {
                                Image(systemName: "plus")
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("在\(list.title)添加待办")
                            .accessibilityIdentifier("tasks.add.\(list.id)")
                        }
                        if drafts[target] != nil { editor(target) }
                        ForEach(buckets[list.id] ?? []) { entry in
                            taskRow(entry.item)
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ item: ReminderItem) -> some View {
        let target = Target.item(item.id)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                model.completeItem(item)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.mutating || drafts[target] != nil)
            .accessibilityLabel("完成 \(item.displayTitle)")
            .accessibilityIdentifier("tasks.complete.\(item.id)")
            if drafts[target] != nil {
                editor(target, current: item)
            } else {
                Button {
                    begin(target, item: item)
                } label: {
                    Text(item.displayTitle)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("编辑标题")
                .accessibilityLabel("编辑 \(item.displayTitle)")
                .accessibilityIdentifier("tasks.edit.\(item.id)")
            }
        }
    }

    private func begin(_ target: Target, item: ReminderItem? = nil) {
        if drafts[target] == nil {
            drafts[target] = Draft(text: item?.displayTitle ?? "", original: item)
        } else {
            focused = target
        }
    }

    private func editor(_ target: Target, current: ReminderItem? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                TextField(
                    "记一条待办…",
                    text: Binding(
                        get: { drafts[target]?.text ?? "" },
                        set: { drafts[target]?.text = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused, equals: target)
                .task {
                    await Task.yield()
                    if !Task.isCancelled { focused = target }
                }
                .onSubmit { submit(target, current: current) }
                .onExitCommand { cancel(target) }
                .accessibilityLabel("待办标题")
                .accessibilityIdentifier("tasks.titleInput")
                Button {
                    submit(target, current: current)
                } label: {
                    Image(systemName: "checkmark").frame(width: 24, height: 26)
                }
                .accessibilityLabel("保存")
                .accessibilityIdentifier("tasks.save")
                .disabled(
                    model.mutating
                        || (drafts[target]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    cancel(target)
                } label: {
                    Image(systemName: "xmark").frame(width: 22, height: 26)
                }
                .accessibilityLabel("取消")
                .accessibilityIdentifier("tasks.cancel")
                .disabled(model.mutating)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) { Divider() }
            if let notice = drafts[target]?.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func cancel(_ target: Target) {
        guard !model.mutating else { return }
        if focused == target { focused = nil }
        drafts.removeValue(forKey: target)
    }

    private func submit(_ target: Target, current: ReminderItem?) {
        guard !model.mutating, let draft = drafts[target] else { return }
        let title = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let saved: @MainActor () -> Void = {
            if drafts[target]?.text == draft.text {
                if focused == target { focused = nil }
                drafts.removeValue(forKey: target)
            } else if var original = draft.original {
                original.title = original.replacingDisplayTitle(with: title)
                drafts[target]?.original = original
            }
        }
        switch target {
        case .list(let listID):
            model.addItem(title: title, listID: listID, onSaved: saved)
        case .item:
            guard let original = draft.original, let current else { return }
            if title == original.displayTitle || title == current.displayTitle {
                cancel(target)
            } else if current.title != original.title {
                drafts[target]?.original = current
                drafts[target]?.notice = "最新标题为「\(current.displayTitle)」。再次保存将采用你的修改。"
            } else {
                model.renameItem(original, to: title, onSaved: saved)
            }
        }
    }
}
