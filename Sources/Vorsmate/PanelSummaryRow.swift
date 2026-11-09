// [INPUT]: 功能名称、管理状态、当前设备 / 实测数值与展开状态。
// [OUTPUT]: 左侧标题 / 状态、右侧当前值的统一摘要行；悬停仅强调箭头，不绘制整行灰底。
// [POS]: 输入法、音频和风扇共用的展示组件；不执行设备控制。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI

struct PanelSummaryRow: View {
    let title: String
    let symbol: String
    let status: String
    var statusSymbol: String? = nil
    let value: String
    let expanded: Bool
    var pending = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18)).frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 4) {
                    if let statusSymbol { Image(systemName: statusSymbol).font(.system(size: 10)) }
                    Text(status)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13)).monospacedDigit()
                .lineLimit(1).truncationMode(.middle).help(value)
            if pending {
                ProgressView().controlSize(.mini).frame(width: 10)
            } else {
                Image(systemName: expanded ? "chevron.up" : "chevron.right")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 10).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
