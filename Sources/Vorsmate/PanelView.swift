// [INPUT]: AppModel、各功能分区与主线程内的 SwiftUI 设置提交。
// [OUTPUT]: 分区清晰的紧凑总览、单项展开、无分隔线的三项菜单与原生面板。
// [POS]: 日常管理的唯一主界面；左侧管理状态、右侧当前值，低频设置收进菜单。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import ServiceManagement
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct PanelView: View {
    @ObservedObject var model: AppModel
    let maximumHeight: CGFloat
    var onHeightChange: (CGFloat) -> Void
    @State private var expandedSection: PanelSection?
    @State private var contentHeight: CGFloat = 360

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
                    })
        }
        .scrollIndicators(.automatic)
        .scrollDisabled(contentHeight <= maximumHeight)
        .frame(width: 386, height: min(contentHeight, maximumHeight))
        .fixedSize()
        .modifier(PanelMaterial())
        .onPreferenceChange(PanelHeightKey.self) { measured in
            guard measured > 0 else { return }
            let height = ceil(measured)
            if contentHeight != height { contentHeight = height }
            onHeightChange(min(height, maximumHeight))
        }
        .onChange(of: model.panelVisible) { _, visible in
            if !visible { expandedSection = nil }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(.tint)
                Text("Vorsmate").font(.title3.weight(.semibold))
                Spacer()
                if model.preview { Text("预览").font(.caption).foregroundStyle(.secondary) }
                Menu {
                    if !model.preview {
                        Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    }
                    Button("关于 Vorsmate") {
                        NSApp.orderFrontStandardAboutPanel(options: [
                            .applicationName: "Vorsmate",
                            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                                as? String ?? "开发版",
                        ])
                    }
                    Button("退出 Vorsmate") { NSApp.terminate(nil) }.keyboardShortcut("q")
                    if model.maintenance {
                        Button("停用风扇助手") { model.fan.uninstallHelper() }.disabled(model.fan.busy)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("更多")
                .accessibilityIdentifier("settings")
            }
            .padding(.horizontal, 20).padding(.top, 17).padding(.bottom, 12)
            if let message = model.configurationError ?? model.loginMessage {
                Text(message).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            if model.loginMessage != nil {
                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link).padding(.horizontal, 20).padding(.bottom, 12)
            }
            TimeComparisonView(isExpanded: expansion(for: .time), panelVisible: model.panelVisible)
            Divider().padding(.horizontal, 20)
            ForEach(model.controllers) { controller in
                ChannelView(controller: controller, expanded: expansion(for: .channel(controller.channel)))
                    .disabled(model.configurationError != nil)
                Divider().padding(.horizontal, 20)
            }
            FanView(model: model.fan, expanded: expansion(for: .fan))
        }.padding(.bottom, 4)
    }

    private func expansion(for section: PanelSection) -> Binding<Bool> {
        Binding(get: { expandedSection == section }, set: { expandedSection = $0 ? section : nil })
    }
}

private enum PanelSection: Equatable {
    case time
    case channel(Channel)
    case fan
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PanelMaterial: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // NSPopover 自带系统玻璃；不再覆盖普通模糊材质。
            content
        } else {
            content.background(.regularMaterial)
        }
    }
}
