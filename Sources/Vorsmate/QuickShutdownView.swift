// [INPUT]: ShutdownController 的应用清单、偏好与可取消执行状态。
// [OUTPUT]: 总览入口与同一面板内的应用选择、退出选项、倒计时和结果。
// [POS]: 动作区固定，长列表单独滚动；系统操作只经控制器。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct ShutdownSummary: View {
    @ObservedObject var controller: ShutdownController
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                PanelSummaryRow(
                    title: "一键下班", symbol: "sunset", status: controller.status,
                    value: "\(controller.appCount) 个应用", navigation: .detail, pending: controller.executing)
            }.buttonStyle(.plain).accessibilityIdentifier("shutdown.summary")
            if let message = controller.error ?? controller.message {
                Text(message).font(.callout).foregroundStyle(controller.error == nil ? Color.secondary : .red)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
        }
    }
}

struct QuickShutdownView: View {
    @ObservedObject var controller: ShutdownController
    let maximumHeight: CGFloat
    let back: () -> Void
    @State private var options = false
    @State private var search = ""
    @State private var headerHeight: CGFloat = 110
    @State private var footerHeight: CGFloat = 80
    @State private var listHeight: CGFloat = 160
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Button {
                    if options { options = false } else { back() }
                } label: {
                    Label(options ? "一键下班" : "Vorsmate", systemImage: "chevron.left")
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
                    Text(title).font(
                        controller.countdown == nil ? .title2.weight(.semibold) : .system(size: 25, weight: .semibold)
                    )
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    if !options {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if !options {
                    SunsetMark(
                        progress: controller.countdown.map {
                            1 - Double($0) / Double(ShutdownController.countdownSeconds)
                        } ?? (controller.executing ? 1 : 0)
                    )
                    .frame(width: 78, height: 42).accessibilityHidden(true)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: controller.countdown)
                }
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
    }

    private var title: String {
        if options { return "下班选项" }
        if let count = controller.countdown, let action = controller.pendingAction {
            return "\(count) 秒后\(action.title)"
        }
        return controller.executing ? "正在\(controller.pendingAction?.title ?? "退出")" : "一键下班"
    }
    private var subtitle: String {
        if controller.executing { return controller.isPreview ? "正在模拟执行" : "正在处理所选应用" }
        if controller.countdown != nil { return "按 Esc 或点击下方按钮取消" }
        return (controller.isPreview ? "模拟预览 · " : "") + "开始后有 \(ShutdownController.countdownSeconds) 秒可以取消"
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
                    .buttonStyle(.link).font(.callout).disabled(busy).accessibilityIdentifier("shutdown.selectAll")
                }
            }
            if searchable {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("查找应用", text: $search).textFieldStyle(.plain).accessibilityIdentifier("shutdown.search")
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                    }
                }.padding(7).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7)).disabled(busy)
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
                        }.padding(.horizontal, 11).frame(minHeight: 39).contentShape(Rectangle())
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
                        if app.id != apps.last?.id { Divider().padding(.leading, 46) }
                    }
                }.background(.quaternary.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if controller.appCount < controller.apps.count {
                Text("未选的应用由系统在关机或重启时退出。").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            setting("强制退出应用", hint: "应用未能正常退出时强制结束，可能丢失未保存的更改。", key: \.forceCloseApps, id: "force")
            Divider()
            setting("下次开机不恢复窗口", hint: "关闭此项时，沿用 macOS 的窗口恢复设置。", key: \.disableReopenWindows, id: "windows")
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
                Label(feedback, systemImage: controller.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout).foregroundStyle(controller.error == nil ? Color.secondary : .red)
            }
            if !options {
                if controller.policy.forceCloseApps && controller.appCount > 0 && !controller.executing {
                    Label("已开启强制退出，未保存的更改可能丢失。", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let action = controller.pendingAction {
                    if controller.countdown != nil {
                        Button {
                            controller.cancel()
                        } label: {
                            Text("取消" + action.title).frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction).accessibilityIdentifier(
                            "shutdown.cancel")
                    } else {
                        ProgressView("正在处理…").controlSize(.small).frame(maxWidth: .infinity)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button {
                            controller.start(.shutdown)
                        } label: {
                            Label("关机", systemImage: "power").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("shutdown.start")
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
