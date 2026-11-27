// [INPUT]: 窗口拖动监听状态、触发键与可持久保存的设置回调。
// [OUTPUT]: 工具分类中的摘要行、原地展开的修饰键菜单与权限入口。
// [POS]: 复用菜单栏面板的摘要与内嵌卡片。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct WindowDragSectionView: View {
    @ObservedObject var monitor: WindowDragMonitor
    @Binding var expanded: Bool
    let setModifier: @MainActor (WindowDragModifier) -> Void
    @Environment(\.panelRowHorizontalPadding) private var horizontalPadding

    private var statusText: String {
        switch monitor.status {
        case .inactive: "已停用"
        case .ready: "按住修饰键，左键拖动"
        case .permissionRequired: "需要辅助功能权限"
        case .unavailable: "鼠标监听未启动"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: PluginID.windowDrag.title, symbol: PluginID.windowDrag.symbol, status: statusText,
                    statusColor: monitor.status.needsAttention ? .red : .secondary,
                    value: monitor.modifier.summaryTitle, navigation: .disclosure(expanded: expanded))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PluginID.windowDrag.title)
            .accessibilityValue("\(statusText)，\(monitor.modifier.title)，\(expanded ? "已展开" : "已收起")")
            .accessibilityIdentifier("windowDrag.expand")

            if expanded {
                PanelInlineCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("修饰键", selection: Binding(get: { monitor.modifier }, set: { setModifier($0) })) {
                            ForEach(WindowDragModifier.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("windowDrag.modifier")
                        if monitor.status == .permissionRequired {
                            Button("打开辅助功能设置") { monitor.openAccessibilitySettings() }
                        } else if monitor.status == .unavailable {
                            Button("重新启动监听") { monitor.refresh() }
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
