// [INPUT]: ChannelController、单项展开绑定与主线程内的 SwiftUI 模式提交。
// [OUTPUT]: 选择、模式、原生拖动优先级与恢复 / 离线 / 发射器就绪反馈。
// [POS]: 三种选择通道复用的界面；由 PanelView 装配，不承担面板生命周期。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct ChannelView: View {
    @ObservedObject var controller: ChannelController
    @Binding var expanded: Bool

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
        }
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
            SourceList(controller: controller)
                .frame(height: CGFloat(min(controller.policy.priority.count, 6)) * 44)
            if controller.policy.priority.isEmpty {
                Text("暂无可用项目").foregroundStyle(.secondary).padding(.vertical, 6)
            }
        }
    }

}
