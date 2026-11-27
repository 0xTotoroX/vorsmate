// [INPUT]: AppModel、BrandIcon、PluginCategory、各功能分区与主线程内的 SwiftUI 设置提交。
// [OUTPUT]: 顶部分类切换栏、浅底分组卡片、单项展开、模块顺序管理与原生面板。
// [POS]: 日常管理的唯一主界面；按设备／工具／系统三分类组织模块，保持单层卡片清晰层次。
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
    @AppStorage("vorsmate.panel.selectedCategory") private var selectedCategoryRaw = PluginCategory.devices.rawValue
    @State private var previewCategoryOverride: PluginCategory?
    @State private var expandedSection: PluginID?
    @State private var remotePage = RemotePanelPage.home
    @State private var remoteAppID: String?
    @State private var remoteGesture = RemoteGesture.single
    @State private var showingTypelessRecovery = false
    @State private var showingPluginManager = false
    @State private var contentHeight: CGFloat = 360

    init(
        model: AppModel,
        maximumHeight: CGFloat,
        protectInteraction: @escaping (Bool) -> Void,
        onHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.model = model
        self.maximumHeight = maximumHeight
        self.protectInteraction = protectInteraction
        self.onHeightChange = onHeightChange
        let initialSection: PluginID? =
            model.preview && CommandLine.arguments.contains("--preview-unattended-detail")
            ? .unattendedAuth : nil
        _expandedSection = State(initialValue: initialSection)
        let previewTools = model.preview && CommandLine.arguments.contains("--preview-translate")
        _previewCategoryOverride = State(initialValue: previewTools ? .tools : nil)
    }

    private var visibleCategories: [PluginCategory] {
        PluginCategory.allCases.filter { category in
            model.orderedEnabledPlugins.contains { $0.defaultCategory == category }
        }
    }

    private var activeCategory: PluginCategory {
        if let previewCategoryOverride, visibleCategories.contains(previewCategoryOverride) {
            return previewCategoryOverride
        }
        if let saved = PluginCategory(rawValue: selectedCategoryRaw), visibleCategories.contains(saved) {
            return saved
        }
        return visibleCategories.first ?? .devices
    }

    var body: some View {
        Group {
            if expandedSection == .quickShutdown {
                QuickShutdownView(
                    controller: model.shutdown,
                    maximumHeight: maximumHeight,
                    protectInteraction: protectInteraction
                ) {
                    expandedSection = nil
                }
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
                    })
            } else if expandedSection == .unattendedAuth {
                UnattendedAuthView(
                    controller: model.unattendedAuth,
                    maximumHeight: maximumHeight,
                    protectInteraction: protectInteraction
                ) {
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
                showingPluginManager = false
                remoteAppID = nil
            }
        }
        .onChange(of: remotePage == .home) { _, home in
            if home { model.remote.endEditing() } else { model.remote.beginEditing() }
        }
    }

    private var overviewScroll: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                Group {
                    if showingPluginManager {
                        PluginOrderManagerView(model: model) {
                            showingPluginManager = false
                        }
                    } else if showingTypelessRecovery {
                        TypelessRecoveryPanel(model: model.typelessRecovery, preview: model.preview) {
                            showingTypelessRecovery = false
                        }
                    } else if remotePage == .home {
                        content
                    } else {
                        RemotePanel(
                            plugin: model.remote, page: $remotePage, gesture: $remoteGesture, appID: $remoteAppID,
                            protectInteraction: protectInteraction,
                            onOpenTypeless: {
                                expandedSection = nil
                                model.typelessRecovery.refresh()
                                showingTypelessRecovery = true
                            })
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
                    })
            }
            .id(showingPluginManager ? -2 : (showingTypelessRecovery ? -1 : remotePage.scrollID))
            .scrollIndicators(.never)
            .scrollDisabled(contentHeight <= maximumHeight)
            .frame(width: 386, height: min(contentHeight, maximumHeight))
            .fixedSize()
            .onChange(of: expandedSection) { _, section in
                guard let section,
                    section != .quickShutdown,
                    section != .unattendedAuth,
                    remotePage == .home,
                    !showingTypelessRecovery,
                    !showingPluginManager
                else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(35))
                    withAnimation(.snappy(duration: 0.2)) {
                        scrollProxy.scrollTo(section, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var content: some View {
        let category = activeCategory
        let categoryPlugins = model.orderedEnabledPlugins.filter { $0.defaultCategory == category }
        let groups = Self.cardGroups(for: categoryPlugins)

        return VStack(spacing: 0) {
            ZStack {
                Image(nsImage: BrandIcon.panelMark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Vorsmate")

                HStack(spacing: 8) {
                    Spacer()
                    if model.preview {
                        Text("预览").font(.caption).foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("功能模块…") {
                            expandedSection = nil
                            showingPluginManager = true
                        }
                        .accessibilityIdentifier("plugins.order")

                        if model.canManageLogin || (!model.preview && !model.development) || model.preview {
                            Divider()
                        }
                        if model.canManageLogin {
                            Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                        }
                        if !model.preview && !model.development {
                            UpdateMenuItem(model: model.updates)
                        }
                        if model.preview {
                            Button("Typeless 诊断与恢复") {
                                expandedSection = nil
                                model.typelessRecovery.refresh()
                                showingTypelessRecovery = true
                            }.accessibilityIdentifier("typeless.open")
                        }

                        Divider()
                        Button("关于 Vorsmate") {
                            NSApp.orderFrontStandardAboutPanel(options: [
                                .applicationName: "Vorsmate",
                                .applicationVersion: Bundle.main.object(
                                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                            ])
                        }
                        Button("退出 Vorsmate") { NSApp.terminate(nil) }.keyboardShortcut("q")
                        if model.maintenance {
                            Button("停用风扇助手") { model.fan.uninstallHelper() }.disabled(model.fan.busy)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("更多")
                    .accessibilityIdentifier("settings")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if visibleCategories.count > 1 {
                categoryBar(selected: category)
            }

            if let message = model.configurationError ?? model.loginMessage {
                PanelInlineNotice(text: message, isError: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            if model.loginMessage != nil {
                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            if model.orderedEnabledPlugins.isEmpty || categoryPlugins.isEmpty {
                PanelSectionCard {
                    VStack(spacing: 10) {
                        Text("当前暂无已启用模块")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("功能模块…") {
                            expandedSection = nil
                            showingPluginManager = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 14)
                }
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 10) {
                    ForEach(groups) { group in
                        switch group {
                        case .time:
                            PanelSectionCard {
                                pluginView(.time)
                                    .id(PluginID.time)
                            }
                        case .list(let items):
                            PanelSectionCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.element) { index, id in
                                        if index > 0 { Divider().padding(.horizontal, 14) }
                                        pluginView(id)
                                            .id(id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 12)
    }

    private func categoryBar(selected: PluginCategory) -> some View {
        HStack(spacing: 3) {
            ForEach(visibleCategories) { category in
                let isSelected = category == selected
                let indicator = isSelected ? .none : model.categoryIndicator(for: category)
                Button {
                    previewCategoryOverride = nil
                    selectedCategoryRaw = category.rawValue
                    expandedSection = nil
                } label: {
                    Image(systemName: category.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.11) : Color.clear)
                        )
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if indicator != .none {
                                Circle()
                                    .fill(indicator == .error ? Color.red : Color.accentColor)
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 5)
                                    .padding(.trailing, 8)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(category.title)
                .accessibilityLabel(category.title)
                .accessibilityIdentifier("panel.category.\(category.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder private func pluginView(_ id: PluginID) -> some View {
        switch id {
        case .time:
            TimeComparisonView(
                isExpanded: expansion(for: id),
                panelVisible: model.panelVisible,
                protectInteraction: protectInteraction)
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
        case .unattendedAuth:
            UnattendedAuthSummary(controller: model.unattendedAuth) { expandedSection = .unattendedAuth }
        case .translate:
            TranslationSectionView(
                model: model.translation,
                expanded: expansion(for: id),
                protectInteraction: protectInteraction)
        }
    }

    private func expansion(for section: PluginID) -> Binding<Bool> {
        Binding(get: { expandedSection == section }, set: { expandedSection = $0 ? section : nil })
    }

    enum PluginCardGroup: Equatable, Identifiable {
        case time
        case list([PluginID])

        var id: String {
            switch self {
            case .time: "time"
            case .list(let ids): ids.map(\.rawValue).joined(separator: ",")
            }
        }
    }

    static func cardGroups(for plugins: [PluginID]) -> [PluginCardGroup] {
        var groups: [PluginCardGroup] = []
        var buffer: [PluginID] = []
        for id in plugins {
            if id == .time {
                if !buffer.isEmpty {
                    groups.append(.list(buffer))
                    buffer.removeAll()
                }
                groups.append(.time)
            } else {
                buffer.append(id)
            }
        }
        if !buffer.isEmpty {
            groups.append(.list(buffer))
        }
        return groups
    }
}

private struct PluginOrderManagerView: View {
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
                    let items = model.orderedAvailablePlugins.filter { $0.defaultCategory == category }
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
                                                Button {
                                                    model.movePlugin(id, in: category, by: -1)
                                                } label: {
                                                    Image(systemName: "arrow.up")
                                                        .font(.system(size: 11, weight: .medium))
                                                        .frame(width: 22, height: 22)
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(index == 0)
                                                .foregroundStyle(index == 0 ? .tertiary : .secondary)
                                                .accessibilityLabel("上移\(id.title)")
                                                .accessibilityIdentifier("plugins.moveUp.\(id.rawValue)")

                                                Button {
                                                    model.movePlugin(id, in: category, by: 1)
                                                } label: {
                                                    Image(systemName: "arrow.down")
                                                        .font(.system(size: 11, weight: .medium))
                                                        .frame(width: 22, height: 22)
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(index == items.count - 1)
                                                .foregroundStyle(index == items.count - 1 ? .tertiary : .secondary)
                                                .accessibilityLabel("下移\(id.title)")
                                                .accessibilityIdentifier("plugins.moveDown.\(id.rawValue)")
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
