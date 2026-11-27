// [INPUT]: TasksModel、PanelSummaryRow/PanelSectionCard 原语、面板最大高度与交互保护回调。
// [OUTPUT]: 总览「待办」摘要行与同宽详情页（Project 分组待办列表、测试分区标签、一键完成、1 行快速添加与 codex:// 打开）。
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

    @State private var draftTitle = ""
    @State private var headerHeight: CGFloat = 120
    @State private var bodyHeight: CGFloat = 180
    @FocusState private var quickAddFocused: Bool

    private var canSubmitDraft: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.mutating
            && !model.projection.projectLists.isEmpty
    }

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
                    .padding(.horizontal, 16)
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
        .onChange(of: quickAddFocused) { _, focused in
            protectInteraction(focused)
        }
        .onDisappear {
            quickAddFocused = false
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
                    } else {
                        Text(model.summaryStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.refresh()
                    } label: {
                        if model.loading || model.mutating {
                            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.loading || model.mutating)
                    .help("刷新待办")
                    .accessibilityLabel("刷新待办")
                    .accessibilityIdentifier("tasks.refresh")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            if model.connectionState == .connected && !model.projection.projectLists.isEmpty {
                quickAddBar
                    .padding(.horizontal, 16)
            }

            if let error = model.actionError, model.connectionState != .readFailed {
                PanelInlineNotice(text: error, symbol: "exclamationmark.triangle.fill", isError: true)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("tasks.error")
            }
        }
        .padding(.bottom, 10)
    }

    private var quickAddBar: some View {
        PanelSectionCard {
            HStack(spacing: 8) {
                Picker(
                    "目标列表",
                    selection: Binding(
                        get: { model.selectedQuickAddListID },
                        set: { model.selectedQuickAddListID = $0 }
                    )
                ) {
                    ForEach(model.projection.projectLists) { list in
                        Text(list.title).tag(list.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("目标列表")
                .accessibilityIdentifier("tasks.addList")

                TextField("添加待办…", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($quickAddFocused)
                    .onSubmit(submitDraft)
                    .accessibilityIdentifier("tasks.addInput")

                Button(action: submitDraft) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(canSubmitDraft ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitDraft)
                .help("添加待办")
                .accessibilityLabel("添加待办")
                .accessibilityIdentifier("tasks.addSubmit")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var scrollContent: some View {
        if model.connectionState == .offline || model.connectionState == .readFailed {
            PanelSectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(
                            systemName: model.connectionState == .offline ? "link.badge.plus" : "exclamationmark.circle"
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        Text(model.connectionState == .offline ? "未连接提醒事项连接器" : "暂时无法读取 Apple 提醒事项")
                            .font(.callout.weight(.semibold))
                    }
                    Text(model.actionError ?? "首次使用，请打开连接器并允许访问 Apple 提醒事项。")
                        .font(.caption)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } else if model.connectionState == .connecting && model.projection.buckets.isEmpty {
            PanelSectionCard {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取 Apple 提醒事项…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } else if model.projection.buckets.isEmpty {
            PanelSectionCard {
                Text("Project 分组暂无未完成待办")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        } else {
            VStack(spacing: 10) {
                ForEach(model.projection.buckets) { bucket in
                    PanelSectionCard {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Text(bucket.list.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 8)
                                Text("\(bucket.items.count)")
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)

                            ForEach(Array(bucket.items.enumerated()), id: \.element.id) { _, entry in
                                Divider().padding(.horizontal, 14)
                                taskRow(entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ entry: ProjectReminderEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.completeItem(entry.item)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.mutating)
            .help("标记为已完成")
            .accessibilityLabel("完成 \(entry.item.title)")
            .accessibilityIdentifier("tasks.complete.\(entry.item.id)")

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if entry.sectionTitle != nil || entry.item.codexURL != nil {
                    HStack(spacing: 6) {
                        if let section = entry.sectionTitle {
                            Text(section)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        if entry.item.codexURL != nil {
                            Button {
                                model.openCodexURL(entry.item)
                            } label: {
                                Label("Codex", systemImage: "arrow.up.forward.app")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("在 Codex 中打开")
                            .accessibilityLabel("在 Codex 中打开 \(entry.item.title)")
                            .accessibilityIdentifier("tasks.codex.\(entry.item.id)")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func submitDraft() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        model.addItem(title: title)
        draftTitle = ""
    }
}
