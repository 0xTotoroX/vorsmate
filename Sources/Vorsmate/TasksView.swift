// [INPUT]: TasksModel、PanelSummaryRow、面板最大高度与交互保护回调。
// [OUTPUT]: 总览「待办」摘要行与同宽详情页（项目清单、勾选完成与一行速记）。
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
                    } else if model.loading {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            if model.connectionState == .connected && !model.projection.projectLists.isEmpty {
                quickAddBar
                    .padding(.horizontal, 20)
            }

            if let error = model.actionError, model.connectionState == .connected {
                PanelInlineNotice(text: error, symbol: "exclamationmark.triangle.fill", isError: true)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("tasks.error")
            }
        }
        .padding(.bottom, 10)
    }

    private var quickAddBar: some View {
        HStack(spacing: 8) {
            TextField("记一条待办…", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($quickAddFocused)
                .onSubmit(submitDraft)
                .accessibilityLabel("待办标题")
                .accessibilityIdentifier("tasks.addInput")

            Picker("存入列表", selection: $model.selectedQuickAddListID) {
                ForEach(model.projection.projectLists) { list in
                    Text(list.title).tag(list.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 112, alignment: .trailing)
            .disabled(model.mutating)
            .accessibilityLabel("存入列表")
            .accessibilityIdentifier("tasks.addList")

            Button(action: submitDraft) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(canSubmitDraft ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitDraft)
            .help("添加待办")
            .accessibilityLabel("添加待办")
            .accessibilityIdentifier("tasks.addSubmit")
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Divider() }
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
        } else if model.projection.buckets.isEmpty {
            Text("暂无未完成待办")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.projection.buckets) { bucket in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bucket.list.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(bucket.items) { entry in
                            Button {
                                model.completeItem(entry.item)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: "circle")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                    Text(entry.item.displayTitle)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.mutating)
                            .help("标记为已完成")
                            .accessibilityLabel("完成 \(entry.item.displayTitle)")
                            .accessibilityIdentifier("tasks.complete.\(entry.item.id)")
                        }
                    }
                }
            }
        }
    }

    private func submitDraft() {
        guard canSubmitDraft else { return }
        let submitted = draftTitle
        model.addItem(title: submitted) {
            if draftTitle == submitted { draftTitle = "" }
        }
    }
}
