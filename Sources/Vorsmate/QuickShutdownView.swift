// [INPUT]: ShutdownController 的应用清单、偏好与可取消执行状态。
// [OUTPUT]: 同一面板内的应用选择、退出选项、准备与取消及提交反馈（倒计时在菜单栏显示）。
// [POS]: 动作区固定，长列表单独滚动；系统操作只经控制器。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct ShutdownSummary: View {
    @ObservedObject var controller: ShutdownController
    let open: () -> Void
    @Environment(\.panelRowHorizontalPadding) private var horizontalPadding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelActionSummaryRow(
                title: PluginID.quickShutdown.title,
                symbol: PluginID.quickShutdown.symbol,
                symbolColor: controller.canCancel ? Color.accentColor : Color.primary,
                status: controller.status,
                value: "\(controller.appCount) 个应用",
                pending: controller.executing,
                summaryIdentifier: "shutdown.summary",
                open: open
            ) {
                if controller.canCancel {
                    Button("取消") {
                        controller.cancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("取消\(controller.pendingAction?.title ?? "")")
                    .accessibilityIdentifier("shutdown.summary.cancel")
                }
            }
            if let message = controller.error ?? controller.message {
                PanelInlineNotice(text: message, isError: controller.error != nil)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 10)
            }
        }
    }
}

struct QuickShutdownView: View {
    @ObservedObject var controller: ShutdownController
    let maximumHeight: CGFloat
    var protectInteraction: (Bool) -> Void = { _ in }
    let back: () -> Void
    @State private var options = false
    @State private var search = ""
    @State private var headerHeight: CGFloat = 110
    @State private var footerHeight: CGFloat = 80
    @State private var listHeight: CGFloat = 160
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var busy: Bool { controller.countdown != nil || controller.executing }
    private var searchable: Bool { controller.apps.count > 6 }
    private var shown: [RunningAppItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? controller.apps : controller.apps.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if !options && !controller.apps.isEmpty { selectionHeader.padding(.horizontal, 20).padding(.bottom, 8) }
            }.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    ceil($0.size.height)
                } action: {
                    headerHeight = $0
                }
            ScrollView {
                Group { if options { settings } else { applications } }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .onGeometryChange(for: CGFloat.self) {
                        ceil($0.size.height)
                    } action: {
                        listHeight = $0
                    }
            }
            .id(options)
            .scrollIndicators(.never)
            .frame(
                height: min(
                    !options && searchable ? 254 : listHeight,
                    max(32, maximumHeight - headerHeight - footerHeight)))
            footer.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    ceil($0.size.height)
                } action: {
                    footerHeight = $0
                }
        }
        .onChange(of: searchable) { _, available in if !available { search = "" } }
        .onChange(of: busy) { _, started in if started { search = "" } }
        .onChange(of: searchFocused) { _, focused in protectInteraction(focused) }
        .onDisappear {
            searchFocused = false
            protectInteraction(false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Button {
                    if options { options = false } else { back() }
                } label: {
                    Label(options ? PluginID.quickShutdown.title : "Vorsmate", systemImage: "chevron.left")
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("shutdown.back")
                Spacer()
                if !options && !busy {
                    Button {
                        options = true
                    } label: {
                        Label("选项", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("shutdown.options")
                }
            }.font(.callout)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    if !options {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if !options {
                    SunsetMark(progress: controller.executing ? 1 : 0)
                        .frame(width: 78, height: 42).accessibilityHidden(true)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: controller.executing)
                }
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
    }

    private var title: String {
        if options { return "关机选项" }
        return controller.executing ? controller.status : PluginID.quickShutdown.title
    }
    private var subtitle: String {
        if controller.submitting { return "等待系统回执" }
        if controller.executing { return "按 Esc 或点击下方按钮取消" }
        if controller.countdown != nil { return "倒计时已在菜单栏显示，鼠标移开仍会继续" }
        return (controller.isPreview ? "模拟预览 · " : "") + "开始后在菜单栏倒计时 \(ShutdownController.countdownSeconds) 秒"
    }

    private var selectionHeader: some View {
        let apps = shown
        let allSelected = !apps.isEmpty && apps.allSatisfy { !controller.policy.excludedBundleIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("提前退出").font(.headline)
                Text("\(controller.appCount)/\(controller.apps.count)").monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("已选 \(controller.appCount) 个，共 \(controller.apps.count) 个应用")
                Spacer()
                if !apps.isEmpty && !busy {
                    Button(search.isEmpty ? (allSelected ? "取消全选" : "全选") : (allSelected ? "取消选中结果" : "选中结果")) {
                        controller.setIncluded(!allSelected, ids: Set(apps.map(\.id)))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
                    .accessibilityIdentifier("shutdown.selectAll")
                }
            }
            if searchable {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("查找应用", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityIdentifier("shutdown.search")
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                    }
                }
                .padding(7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
                .disabled(busy)
            }
        }
    }

    private var applications: some View {
        let apps = shown
        return VStack(alignment: .leading, spacing: 8) {
            if apps.isEmpty {
                Text(controller.apps.isEmpty ? "当前没有需要提前退出的应用" : "没有匹配的应用")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 15)
            } else {
                PanelSectionCard {
                    VStack(spacing: 0) {
                        ForEach(apps) { app in
                            let included = !controller.policy.excludedBundleIDs.contains(app.id)
                            let row = HStack(spacing: 10) {
                                ShutdownAppIcon(app: app, preview: controller.isPreview)
                                Text(app.name).lineLimit(1).truncationMode(.tail).help(app.name)
                                Spacer(minLength: 8)
                                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(included ? Color.accentColor : Color.secondary)
                            }.padding(.horizontal, 12).frame(minHeight: 39).contentShape(Rectangle())
                            if busy {
                                row.accessibilityElement(children: .ignore).accessibilityLabel(app.name)
                                    .accessibilityValue(included ? "提前退出" : "跳过")
                            } else {
                                Button {
                                    controller.toggleExcluded(app.id)
                                } label: {
                                    row
                                }
                                .buttonStyle(ShutdownAppRowStyle()).accessibilityLabel(app.name)
                                .accessibilityValue(included ? "提前退出" : "跳过")
                                .accessibilityAddTraits(included ? .isSelected : [])
                                .accessibilityIdentifier("shutdown.app." + app.id)
                            }
                            if app.id != apps.last?.id { Divider().padding(.leading, 47) }
                        }
                    }
                }
            }
            if controller.appCount < controller.apps.count {
                Text("未选的应用由系统在关机或重启时退出。").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        PanelSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                setting("强制退出应用", hint: "应用未能正常退出时强制结束，可能丢失未保存的更改。", key: \.forceCloseApps, id: "force")
                Divider()
                setting("下次开机不恢复窗口", hint: "关闭此项时，沿用 macOS 的窗口恢复设置。", key: \.disableReopenWindows, id: "windows")
                Text("设置即时生效，返回即可使用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }
    private func setting(_ title: String, hint: String, key: WritableKeyPath<ShutdownPolicy, Bool>, id: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                Toggle(
                    title,
                    isOn: Binding(
                        get: { controller.policy[keyPath: key] },
                        set: {
                            var policy = controller.policy
                            policy[keyPath: key] = $0
                            controller.updatePolicy(policy)
                        })
                ).labelsHidden().toggleStyle(.switch).accessibilityLabel(title).accessibilityIdentifier(
                    "shutdown." + id)
            }
            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let feedback = controller.error ?? controller.message {
                PanelInlineNotice(
                    text: feedback,
                    symbol: controller.error == nil ? "checkmark.circle" : "exclamationmark.circle",
                    isError: controller.error != nil)
            }
            if !options {
                if controller.policy.forceCloseApps && controller.appCount > 0 && !controller.executing {
                    PanelInlineNotice(text: "已开启强制退出，未保存的更改可能丢失。", symbol: "exclamationmark.triangle")
                }
                if let action = controller.pendingAction {
                    if controller.submitting {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                            .accessibilityLabel(controller.status)
                    } else {
                        Button {
                            controller.cancel()
                        } label: {
                            Text("取消" + action.title).frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction).accessibilityIdentifier(
                            "shutdown.cancel")
                    }
                } else {
                    HStack(spacing: 8) {
                        Button {
                            controller.start(.shutdown)
                        } label: {
                            Label("关机", systemImage: "power").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(controller.policy.forceCloseApps && controller.appCount > 0 ? .red : nil)
                        .accessibilityIdentifier("shutdown.start")
                        Button {
                            controller.start(.restart)
                        } label: {
                            Label("重启", systemImage: "arrow.clockwise").padding(.horizontal, 6)
                        }.buttonStyle(.bordered).accessibilityIdentifier("shutdown.restart")
                    }
                }
            }
        }.controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 9))
            .padding(.horizontal, 20).padding(.top, searchable && !options ? 10 : 0)
            .padding(.bottom, options ? 4 : 16)
    }
}

private struct ShutdownAppRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.05 : 0))
            .onHover { hovering = $0 }
    }
}

private struct ShutdownAppIcon: View {
    let app: RunningAppItem
    let preview: Bool
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                let style: (String, Color) =
                    switch app.id {
                    case "preview.editor": ("doc.text.fill", .blue)
                    case "preview.browser": ("safari.fill", .teal)
                    case "preview.notes": ("note.text", .orange)
                    default: ("app.fill", .secondary)
                    }
                Image(systemName: style.0).font(.system(size: 15, weight: .medium)).foregroundStyle(style.1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(style.1.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
            }
        }.frame(width: 25, height: 25).accessibilityHidden(true)
            .task(id: app.id) {
                if !preview, let pid = app.pids.first, let process = NSRunningApplication(processIdentifier: pid),
                    process.bundleIdentifier == app.bundleID
                {
                    icon = process.icon
                }
            }
    }
}

private struct SunsetMark: View, Animatable {
    nonisolated var progress: Double
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let r = h * 0.39
            let x = w * 0.59
            let y = h * (0.58 + 0.65 * progress)
            var ridge = Path()
            ridge.move(to: CGPoint(x: 1, y: h * 0.68))
            ridge.addCurve(
                to: CGPoint(x: w - 1, y: h * 0.64),
                control1: CGPoint(x: w * 0.35, y: h * 0.99), control2: CGPoint(x: w * 0.66, y: h * 0.49))
            var above = ridge
            above.addLine(to: CGPoint(x: w, y: 0))
            above.addLine(to: .zero)
            above.closeSubpath()
            var sky = ctx
            sky.clip(to: above)
            let sun = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            sky.fill(
                sun,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 1, green: 0.75, blue: 0.38), Color(red: 0.95, green: 0.43, blue: 0.22),
                    ]), startPoint: CGPoint(x: x, y: y - r), endPoint: CGPoint(x: x, y: y + r)))
            for angle in [-150.0, -115, -72, -34] {
                let a = angle * .pi / 180
                var ray = Path()
                ray.move(to: CGPoint(x: x + (r + 3) * cos(a), y: y + (r + 3) * sin(a)))
                ray.addLine(to: CGPoint(x: x + (r + 6) * cos(a), y: y + (r + 6) * sin(a)))
                sky.stroke(
                    ray, with: .color(.orange.opacity(0.65 * (1 - progress))),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
            ctx.stroke(ridge, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            var near = Path()
            near.move(to: CGPoint(x: w * 0.19, y: h * 0.96))
            near.addQuadCurve(to: CGPoint(x: w * 0.80, y: h * 0.84), control: CGPoint(x: w * 0.52, y: h * 0.97))
            ctx.stroke(near, with: .color(.orange.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }
}
