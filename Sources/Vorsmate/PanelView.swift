// [INPUT]: AppModel、BrandIcon、各功能分区与主线程内的 SwiftUI 设置提交。
// [OUTPUT]: 分区清晰的紧凑总览、单项展开、含可用模块开关的无分隔线菜单与原生面板。
// [POS]: 日常管理的唯一主界面；左侧管理状态、右侧当前值，低频设置收进菜单。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import ServiceManagement
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct PanelView: View {
    @ObservedObject var model: AppModel
    let maximumHeight: CGFloat
    var protectInteraction: (Bool) -> Void
    var onHeightChange: (CGFloat) -> Void
    @State private var expandedSection: PluginID?
    @State private var remotePage = RemotePanelPage.home
    @State private var remoteAppID: String?
    @State private var remoteGesture = RemoteGesture.single
    @State private var showingTypelessRecovery = false
    @State private var contentHeight: CGFloat = 360

    var body: some View {
        Group {
            if expandedSection == .quickShutdown {
                QuickShutdownView(controller: model.shutdown, maximumHeight: maximumHeight) {
                    model.shutdown.cancel()
                    expandedSection = nil
                }
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
                    })
            } else {
                overviewScroll
            }
        }
        .frame(width: 386)
        .modifier(PanelMaterial())
        .onPreferenceChange(PanelHeightKey.self) { measured in
            guard measured > 0 else { return }
            let height = ceil(measured)
            if contentHeight != height { contentHeight = height }
            onHeightChange(min(height, maximumHeight))
        }
        .onChange(of: model.enabledPlugins) { _, enabled in
            if !enabled.contains(.remote) { remotePage = .home }
            if let expandedSection, !enabled.contains(expandedSection) { self.expandedSection = nil }
        }
        .onChange(of: model.panelVisible) { _, visible in
            if !visible {
                expandedSection = nil
                remotePage = .home
                remoteGesture = .single
                showingTypelessRecovery = false
                remoteAppID = nil
            }
        }
        .onChange(of: remotePage == .home) { _, home in
            if home { model.remote.endEditing() } else { model.remote.beginEditing() }
        }
    }

    private var overviewScroll: some View {
        ScrollView {
            Group {
                if showingTypelessRecovery {
                    TypelessRecoveryPanel(model: model.typelessRecovery, preview: model.preview) {
                        showingTypelessRecovery = false
                    }
                } else if remotePage == .home {
                    content
                } else {
                    RemotePanel(
                        plugin: model.remote, page: $remotePage, gesture: $remoteGesture, appID: $remoteAppID,
                        protectInteraction: protectInteraction)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
                })
        }
        .id(showingTypelessRecovery ? -1 : remotePage.scrollID)
        .scrollIndicators(.automatic)
        .scrollDisabled(contentHeight <= maximumHeight)
        .frame(width: 386, height: min(contentHeight, maximumHeight))
        .fixedSize()
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: BrandIcon.template).resizable().scaledToFit()
                    .frame(width: 18, height: 18).accessibilityHidden(true)
                Text("Vorsmate").font(.title3.weight(.semibold))
                Spacer()
                if model.preview {
                    Text("预览").font(.caption).foregroundStyle(.secondary)
                } else if model.development {
                    Text("开发版").font(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    Menu("功能模块") {
                        ForEach(model.availablePlugins) { id in
                            Toggle(
                                id.title,
                                isOn: Binding(
                                    get: { model.enabledPlugins.contains(id) },
                                    set: { model.setPlugin(id, enabled: $0) }))
                        }
                    }
                    if !model.preview && !model.development {
                        Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                        UpdateMenuItem(model: model.updates)
                    }
                    Button("Typeless 诊断与恢复") {
                        expandedSection = nil
                        model.typelessRecovery.refresh()
                        showingTypelessRecovery = true
                    }.accessibilityIdentifier("typeless.open")
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
            ForEach(Array(model.enabledPlugins.enumerated()), id: \.element) { index, id in
                if index > 0 { Divider().padding(.horizontal, 20) }
                pluginView(id)
            }
        }.padding(.bottom, 4)
    }

    @ViewBuilder private func pluginView(_ id: PluginID) -> some View {
        switch id {
        case .time:
            TimeComparisonView(isExpanded: expansion(for: id), panelVisible: model.panelVisible)
        case .inputSource, .audioInput, .audioOutput:
            if let controller = model.controllers.first(where: { $0.channel == id.channel }) {
                ChannelView(controller: controller, expanded: expansion(for: id))
                    .disabled(model.configurationError != nil)
            }
        case .remote:
            RemoteRow(plugin: model.remote) {
                expandedSection = nil
                remotePage = .overview
            }
        case .fan:
            FanView(model: model.fan, expanded: expansion(for: id), enablesHelperInstallation: !model.development)
        case .quickShutdown: ShutdownSummary(controller: model.shutdown) { expandedSection = .quickShutdown }
        }
    }
    private func expansion(for section: PluginID) -> Binding<Bool> {
        Binding(get: { expandedSection == section }, set: { expandedSection = $0 ? section : nil })
    }
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
