// [INPUT]: ChannelController、单项展开绑定、PanelInlineCard/PanelInlineNotice 原语与主线程内的 SwiftUI 模式提交。
// [OUTPUT]: 选择、模式、原生拖动优先级与恢复／离线／发射器就绪反馈。
// [POS]: 三种选择通道复用的界面；由 PanelView 装配，不承担面板生命周期。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct ChannelView: View {
    @ObservedObject var controller: ChannelController
    @Binding var expanded: Bool
    @Environment(\.panelRowHorizontalPadding) private var horizontalPadding

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
                    title: controller.channel.title,
                    symbol: controller.channel.symbol,
                    status: status,
                    statusSymbol: controller.mode == "locked" && !controller.recovering && !controller.suspended
                        ? "lock.fill" : nil,
                    value: currentName,
                    navigation: .disclosure(expanded: expanded),
                    pending: controller.pending)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.channel.title)
            .accessibilityValue("\(currentName)，\(status)，\(expanded ? "已展开" : "已收起")")
            .accessibilityIdentifier("selection.\(controller.channel.rawValue)")

            if expanded {
                PanelInlineCard {
                    controls
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 12)
            }

            if let error = controller.error {
                VStack(alignment: .leading, spacing: 6) {
                    PanelInlineNotice(text: error, isError: true)
                    Button("重试") { controller.retry() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 12)
            } else if let waiting = controller.waitingName {
                PanelInlineNotice(text: waitingMessage(waiting), symbol: "clock")
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 12)
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
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            SourceList(controller: controller)
                .opacity(controller.mode == "off" ? 0.65 : 1)
                .frame(
                    height: (controller.policy.priority.count > 8 ? 7.5 : CGFloat(controller.policy.priority.count))
                        * 44)

            if controller.policy.priority.isEmpty {
                Text("暂无可用项目")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else if controller.mode == "off" {
                Text("由系统管理，点击项目将切换并锁定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if controller.mode == "auto", controller.policy.priority.count > 1 {
                Text("拖动项目可调整自动切换优先级")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
