// [INPUT]: ChannelController、单项展开绑定与主线程内的 SwiftUI 模式提交。
// [OUTPUT]: 选择、模式、优先级与恢复 / 离线 / 发射器就绪反馈。
// [POS]: 三种选择通道复用的界面；由 PanelView 装配，不承担面板生命周期。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct ChannelView: View {
    @ObservedObject var controller: ChannelController
    @Binding var expanded: Bool
    @State private var priorityExpanded = false

    private var status: String {
        if controller.suspended { return "已暂停" }
        if controller.recovering { return "恢复中" }
        switch controller.mode {
        case "auto": return "自动"
        case "locked": return controller.waitingName == nil ? "已锁定" : "等待接入"
        default: return "关闭"
        }
    }
    private var currentName: String { controller.snapshot.selected?.name ?? "暂无可用项目" }
    private func waitingMessage(_ name: String) -> String {
        guard let id = controller.policy.lockedID, let availability = controller.snapshot.availability[id] else {
            return "等待 \(name) 接入"
        }
        return availability == .waitingForTransmitter ? "等待 \(name) 发射器连接" : "等待 \(name) 确认连接"
    }
    private var availableSources: [Source] {
        controller.policy.priority.filter { source in controller.snapshot.sources.contains { $0.id == source.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: controller.channel.title, symbol: controller.channel.symbol,
                    status: status,
                    statusSymbol: controller.mode == "locked" && !controller.recovering && !controller.suspended
                        ? "lock.fill" : nil,
                    value: currentName, expanded: expanded, pending: controller.pending)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.channel.title)
            .accessibilityValue("\(currentName)，\(status)，\(expanded ? "已展开" : "已收起")")
            .accessibilityIdentifier("selection.\(controller.channel.rawValue)")
            if expanded {
                controls
                    .padding(12)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let error = controller.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("重试") { controller.retry() }.buttonStyle(.link)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            } else if let waiting = controller.waitingName {
                Label(waitingMessage(waiting), systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }.onChange(of: expanded) { _, value in if !value { priorityExpanded = false } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                controller.channel.title + "模式",
                selection: Binding(get: { controller.mode }, set: { controller.setMode($0) })
            ) {
                Text("关闭").tag("off")
                Text("自动").tag("auto")
                Text("锁定").tag("locked")
            }.labelsHidden().pickerStyle(.segmented)
            VStack(spacing: 0) {
                ForEach(availableSources) { source in
                    Button {
                        controller.select(source.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(source.name).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if let label = controller.snapshot.availability[source.id]?.label {
                                Text(label).font(.callout).foregroundStyle(.secondary)
                            }
                            if source.id == controller.snapshot.selectedID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择\(controller.channel.title) \(source.name)")
                    .accessibilityValue(
                        controller.snapshot.availability[source.id]?.label
                            ?? (source.id == controller.snapshot.selectedID ? "当前使用" : ""))
                }
                if availableSources.isEmpty { Text("暂无可用项目").foregroundStyle(.secondary).padding(.vertical, 6) }
            }
            Divider()
            Button {
                priorityExpanded.toggle()
            } label: {
                HStack {
                    Text("调整优先级")
                    Spacer()
                    Image(systemName: priorityExpanded ? "chevron.up" : "chevron.right").font(.caption)
                }.padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(controller.channel.title)优先级")
            .accessibilityValue(priorityExpanded ? "已展开" : "已收起")
            .accessibilityIdentifier("priority.\(controller.channel.rawValue)")
            if priorityExpanded {
                VStack(spacing: 2) {
                    ForEach(Array(controller.policy.priority.enumerated()), id: \.element.id) { index, source in
                        priorityRow(source, index: index)
                    }
                }.font(.callout)
            }
        }
    }

    private func priorityRow(_ source: Source, index: Int) -> some View {
        let online = controller.snapshot.sources.contains { $0.id == source.id }
        return HStack(spacing: 9) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 14)
            Text(source.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(online ? .primary : .secondary)
            if !online {
                Text("离线").font(.caption).foregroundStyle(.secondary)
            } else if let label = controller.snapshot.availability[source.id]?.label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                controller.move(source.id, by: -1)
            } label: {
                Image(systemName: "chevron.up").frame(width: 22, height: 22)
            }
            .disabled(index == 0).accessibilityLabel("提高\(controller.channel.title) \(source.name) 优先级")
            Button {
                controller.move(source.id, by: 1)
            } label: {
                Image(systemName: "chevron.down").frame(width: 22, height: 22)
            }
            .disabled(index == controller.policy.priority.count - 1).accessibilityLabel(
                "降低\(controller.channel.title) \(source.name) 优先级")
            if !online, source.id != controller.policy.lockedID {
                Button {
                    controller.forget(source.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("移除 \(source.name)")
            }
        }.buttonStyle(.borderless).padding(.vertical, 5)
    }
}
