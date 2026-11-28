// [INPUT]: 功能名称、管理状态、当前设备／实测数值、展开状态及分组卡片／内联卡片／提示配置。
// [OUTPUT]: 统一总览摘要行（PanelSummaryRow / PanelActionSummaryRow）、浅底分组卡片（PanelSectionCard）、内联展开卡片（PanelInlineCard）与内联提示（PanelInlineNotice）。
// [POS]: 主面板各功能模块共用的界面原语层；统一字号、间距、圆角与状态反馈，不承担业务逻辑。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI

private struct PanelRowHorizontalPaddingKey: EnvironmentKey {
    static let defaultValue: CGFloat = 20
}

extension EnvironmentValues {
    var panelRowHorizontalPadding: CGFloat {
        get { self[PanelRowHorizontalPaddingKey.self] }
        set { self[PanelRowHorizontalPaddingKey.self] = newValue }
    }
}

struct PanelSummaryRow: View {
    let title: String
    let symbol: String
    var symbolColor: Color = .primary
    let status: String
    var statusSymbol: String? = nil
    var statusColor: Color = .secondary
    let value: String
    var valueColor: Color = .primary
    let navigation: Navigation
    var pending = false
    var horizontalPadding: CGFloat? = nil
    @Environment(\.panelRowHorizontalPadding) private var envHorizontalPadding
    @State private var hovering = false

    enum Navigation {
        case disclosure(expanded: Bool)
        case detail

        var symbol: String {
            switch self {
            case .disclosure(let expanded): expanded ? "chevron.up" : "chevron.down"
            case .detail: "chevron.right"
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(symbolColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 4) {
                    if let statusSymbol { Image(systemName: statusSymbol).font(.system(size: 10)) }
                    Text(status)
                }
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
            if pending {
                ProgressView().controlSize(.mini).frame(width: 10)
            } else {
                Image(systemName: navigation.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 10)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, horizontalPadding ?? envHorizontalPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct PanelActionSummaryRow<Trailing: View>: View {
    let title: String
    let symbol: String
    var symbolColor: Color = .primary
    let status: String
    var statusSymbol: String? = nil
    var statusColor: Color = .secondary
    let value: String?
    var pending = false
    var horizontalPadding: CGFloat? = nil
    var summaryIdentifier: String? = nil
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    let open: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.panelRowHorizontalPadding) private var envHorizontalPadding
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            summaryButton
            trailing()
            if pending {
                ProgressView().controlSize(.mini).frame(width: 10)
            } else {
                Button(action: open) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hovering ? .primary : .secondary)
                        .frame(width: 10, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, horizontalPadding ?? envHorizontalPadding)
        .padding(.vertical, 12)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var summaryButton: some View {
        let base = Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(symbolColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 4) {
                        if let statusSymbol { Image(systemName: statusSymbol).font(.system(size: 10)) }
                        Text(status)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(value)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)

        if let summaryIdentifier, let accessibilityValue {
            base.accessibilityIdentifier(summaryIdentifier).accessibilityValue(accessibilityValue)
        } else if let summaryIdentifier {
            base.accessibilityIdentifier(summaryIdentifier)
        } else if let accessibilityValue {
            base.accessibilityValue(accessibilityValue)
        } else {
            base
        }
    }
}

struct PanelSectionCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.panelRowHorizontalPadding, 14)
            .background(
                reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                    : AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.55)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct PanelInlineCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

struct PanelInlineNotice: View {
    let text: String
    var symbol: String? = nil
    var isError = false

    var body: some View {
        Group {
            if let symbol {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .font(.callout)
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
