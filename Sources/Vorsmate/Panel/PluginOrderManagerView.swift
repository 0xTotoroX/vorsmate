// [INPUT]: AppModel 的可用模块、启停与排序状态。
// [OUTPUT]: 分组的模块管理页，通过应用组合入口保存用户选择。
// [POS]: 面板导航的管理页面，沿用总览的分类和顺序。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore

struct PluginOrderManagerView: View {
    @ObservedObject var model: AppModel
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: back) {
                    Label("Vorsmate", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .accessibilityIdentifier("plugins.back")

                HStack(spacing: 8) {
                    Text("功能模块")
                        .font(.title2.weight(.semibold))
                    Spacer(minLength: 8)
                    if model.hasCustomPluginOrder {
                        Button("恢复默认") {
                            model.resetPluginOrder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("plugins.resetOrder")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(PluginCategory.allCases) { category in
                    let items = category.orderedPlugins(in: model.orderedAvailablePlugins)
                    let movableCount = items.filter(category.canReorder).count
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(category.title, systemImage: category.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            PanelSectionCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.element) { index, id in
                                        let enabled = model.enabledPlugins.contains(id)
                                        let canMoveUp = category.canReorder(id) && index > 0
                                        let canMoveDown = index < movableCount - 1
                                        if index > 0 {
                                            Divider().padding(.horizontal, 14)
                                        }
                                        HStack(spacing: 10) {
                                            Image(systemName: id.symbol)
                                                .font(.system(size: 14))
                                                .foregroundStyle(enabled ? .primary : .tertiary)
                                                .frame(width: 20)
                                                .accessibilityHidden(true)
                                            Text(id.title)
                                                .font(.callout)
                                                .foregroundStyle(enabled ? .primary : .secondary)
                                            Spacer(minLength: 8)
                                            HStack(spacing: 6) {
                                                moveButton(id, category: category, direction: .up, enabled: canMoveUp)
                                                moveButton(
                                                    id, category: category, direction: .down, enabled: canMoveDown)
                                            }
                                            Toggle(
                                                "启用\(id.title)",
                                                isOn: Binding(
                                                    get: { model.enabledPlugins.contains(id) },
                                                    set: { model.setPlugin(id, enabled: $0) })
                                            )
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .controlSize(.small)
                                            .accessibilityIdentifier("plugins.toggle.\(id.rawValue)")
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private enum Direction {
        case up
        case down

        var offset: Int { self == .up ? -1 : 1 }
        var symbol: String { self == .up ? "arrow.up" : "arrow.down" }
        var label: String { self == .up ? "上移" : "下移" }
        var identifier: String { self == .up ? "moveUp" : "moveDown" }
    }

    private func moveButton(
        _ id: PluginID, category: PluginCategory, direction: Direction, enabled: Bool
    ) -> some View {
        Button {
            model.movePlugin(id, in: category, by: direction.offset)
        } label: {
            Image(systemName: direction.symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? .secondary : .tertiary)
        .accessibilityLabel("\(direction.label)\(id.title)")
        .accessibilityIdentifier("plugins.\(direction.identifier).\(id.rawValue)")
    }
}
