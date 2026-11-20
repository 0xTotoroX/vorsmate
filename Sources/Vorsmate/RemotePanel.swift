// [INPUT]: 已验证插件回读的配置、连接与权限状态，及同目录插件的 RC003 投影。
// [OUTPUT]: 菜单栏内的全键总览、位置选键和单手势编辑。
import AppKit
import SwiftUI
import VorsmateCore
import VorsmateRemoteUI

enum RemotePanelPage: Equatable {
    case home, overview
    case detail(RemoteButton)
    var scrollID: Int {
        switch self {
        case .home: 0
        case .overview: 1
        case .detail: 2
        }
    }
}

struct RemotePanel: View {
    @ObservedObject var plugin: RemoteCompanion
    @Binding var page: RemotePanelPage
    @Binding var gesture: RemoteGesture
    @Binding var appID: String?
    let protectInteraction: (Bool) -> Void
    @State private var recording: UUID?
    @State private var pressedRow: RemoteButton?
    @State private var addingID: String?
    @State private var deleting: (id: String, revision: UUID)?

    private let buttons: [RemoteButton] = [
        .ok, .power, .up, .down, .left, .right, .back, .home, .volumeUp, .volumeDown, .menu, .tv, .voice,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                cancelCapture()
                page = page == .overview ? .home : .overview
            } label: {
                Label(page == .overview ? "Vorsmate" : "遥控器", systemImage: "chevron.left")
            }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("remote.back")

            if let state = plugin.editor {
                switch page {
                case .home: EmptyView()
                case .overview: overview(state)
                case .detail(let key): detail(key, state)
                }
                if let problem = plugin.editorError ?? state.problem ?? state.feedback {
                    Text(problem).foregroundStyle(.red).font(.callout)
                }
                if state.needsInput { Button("打开输入监控设置") { plugin.requestPermission(input: true) } }
                if state.needsPost { Button("允许发送系统按键") { plugin.requestPermission(input: false) } }
            } else if let issue = plugin.editorError {
                Text(issue).font(.callout)
                Button("重新连接") { plugin.beginEditing() }
            } else {
                ProgressView("正在读取按键配置").controlSize(.small)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: page) { _, _ in cancelCapture() }
        .onChange(of: gesture) { _, _ in cancelCapture() }
        .onChange(of: appID) { _, _ in cancelCapture() }
        .onChange(of: plugin.editor?.revision) { _, _ in
            guard let state = plugin.editor else { return }
            if let addingID, state.profile.applications?[addingID] != nil {
                appID = addingID
                self.addingID = nil
            } else if let appID, state.profile.applications?[appID] == nil {
                self.appID = nil
            }
        }
        .confirmationDialog(
            "移除这个应用的专属键位？",
            isPresented: Binding(
                get: { deleting != nil },
                set: {
                    if !$0 {
                        deleting = nil
                        protectInteraction(false)
                    }
                })
        ) {
            if let deleting {
                Button("移除方案", role: .destructive) {
                    plugin.configure(.removeApp(id: deleting.id), revision: deleting.revision)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onDisappear {
            cancelCapture()
            if deleting != nil {
                deleting = nil
                protectInteraction(false)
            }
        }
    }

    private var gestures: some View {
        Picker("手势", selection: $gesture) {
            ForEach(RemoteGesture.allCases) { Text($0.name).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
    }

    private func overview(_ state: RemoteEditorState) -> some View {
        let highlighted = Set(state.highlightedButtons ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                page = .detail(.ok)
            } label: {
                HStack(spacing: 12) {
                    if let face = plugin.face {
                        RemoteFaceArtwork(
                            image: face, scale: 65 / 1440, highlighted: highlighted.union(pressedRow.map { [$0] } ?? [])
                        ).frame(width: 32)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("遥控器").font(.title2.weight(.semibold))
                        Text("小米蓝牙遥控器 2 Pro").font(.callout)
                        Text(state.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("小米蓝牙遥控器 2 Pro，" + state.status)
                .accessibilityHint("打开模型，选择实体按键")
                .accessibilityIdentifier("remote.position")
            scopePicker(state)
            gestures
            let mapping = state.profile.resolved(for: appID)
            VStack(spacing: 0) {
                ForEach(buttons) { key in
                    let value = key == .voice ? "按住说话" : mapping.action(for: key, gesture: gesture).title
                    Button {
                        page = .detail(key)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: key.symbol).frame(width: 19).accessibilityHidden(true)
                            Text(key.name)
                            Spacer(minLength: 6)
                            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 28).contentShape(Rectangle())
                        .background(highlighted.contains(key) ? Color.blue.opacity(0.12) : .clear)
                    }.buttonStyle(
                        RemoteRowPressStyle { down in
                            if down { pressedRow = key } else if pressedRow == key { pressedRow = nil }
                        }
                    ).accessibilityLabel("\(key.name)，\(value)").accessibilityIdentifier(
                        "remote.key.\(key.rawValue)")
                    if key != buttons.last { Divider() }
                }
            }
        }
    }

    @ViewBuilder private func detail(_ key: RemoteButton, _ state: RemoteEditorState) -> some View {
        let selection = Binding<RemoteButton>(
            get: { key },
            set: { button in
                cancelCapture()
                page = .detail(button)
            })
        scopePicker(state)
        Menu {
            ForEach(buttons) { button in Button(button.name) { selection.wrappedValue = button } }
        } label: {
            Text(key.name).font(.title2.weight(.semibold))
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("选择实体键，\(key.name)")
        RemoteFace(
            selected: selection, image: plugin.face, scale: 0.22, highlighted: Set(state.highlightedButtons ?? [])
        )
        .frame(maxWidth: .infinity).padding(.vertical, 2)
        if key == .voice {
            LabeledContent("按住说话", value: "MiRemoteV 2ch")
            Text(state.voice).font(.callout).foregroundStyle(.secondary)
            if state.profile.voiceFn { LabeledContent("同时发送", value: "Fn / 地球键") }
        } else {
            gestures
            let binding = state.profile.resolved(for: appID).buttons[key.rawValue] ?? RemoteBinding()
            let override = appID.flatMap { state.profile.applications?[$0]?.buttons[key.rawValue] }
            let saved = binding[gesture]
            let action = saved.editableAction
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("动作")
                    Spacer()
                    Menu(
                        appID != nil && override?.actions[gesture.rawValue] == nil
                            ? "沿用默认 · " + action.kind.title : action.kind.title
                    ) {
                        if appID != nil {
                            Button("沿用默认动作") { setAction(nil, key: key, revision: state.revision) }
                            Divider()
                        }
                        ForEach(RemoteAction.Kind.choices, id: \.self) { kind in
                            Button(kind.title) { choose(kind, key: key, revision: state.revision) }
                        }
                    }.fixedSize().accessibilityIdentifier("remote.action")
                }
                if let revision = recording {
                    Divider()
                    HStack {
                        KeyRecorder { captured in
                            guard recording != nil else { return }
                            cancelCapture()
                            setAction(captured, key: key, revision: revision)
                        }.frame(height: 24)
                        Button("取消") { cancelCapture() }
                    }
                } else if action.kind == .shortcut {
                    Divider()
                    HStack {
                        Text("快捷键")
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(Array(action.keycaps.enumerated()), id: \.offset) { _, label in
                                Text(label).font(.callout.weight(.medium))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }.accessibilityElement(children: .ignore).accessibilityLabel(action.title)
                    }
                    Button("重新录入") { beginCapture(state.revision) }.buttonStyle(.link).accessibilityIdentifier(
                        "remote.record")
                } else if action.kind == .openApplication {
                    LabeledContent("应用", value: action.title)
                    Button("更换应用…") { choose(.openApplication, key: key, revision: state.revision) }.buttonStyle(.link)
                }
                Divider()
                HStack {
                    Text("按住时")
                    Spacer()
                    let mode = binding.hold ?? .once
                    let inherited = appID != nil && override?.hold == nil
                    Menu((inherited ? "沿用默认 · " : "") + mode.title) {
                        if appID != nil {
                            Button("沿用默认方式") {
                                plugin.configure(.hold(app: appID, button: key, mode: nil), revision: state.revision)
                            }
                            Divider()
                        }
                        ForEach(RemoteHoldMode.allCases, id: \.self) { mode in
                            Button(mode.title) {
                                plugin.configure(.hold(app: appID, button: key, mode: mode), revision: state.revision)
                            }.disabled(
                                (mode == .repeatSingle && binding.single.kind == .none)
                                    || (mode == .repeatLong && binding.long.kind == .none))
                        }
                    }.fixedSize().accessibilityIdentifier("remote.hold")
                }
                if let mode = binding.hold, mode != .once {
                    let repeated = mode == .repeatSingle ? binding.single : binding.long
                    Text(repeated.kind == .none ? "先设置要连发的动作" : "按住后连续执行「" + repeated.title + "」，松手停止")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if binding.rapid {
                    Text("允许快速连按").font(.callout).foregroundStyle(.secondary)
                }
            }.disabled(plugin.pending != nil || state.problem != nil)
        }
    }

    private func beginCapture(_ revision: UUID?) {
        guard let revision else { return }
        protectInteraction(true)
        recording = revision
    }

    private func cancelCapture() {
        if recording != nil {
            recording = nil
            protectInteraction(false)
        }
    }

    private func scopePicker(_ state: RemoteEditorState) -> some View {
        let maps = state.profile.applications ?? [:]
        let active = state.frontApp.flatMap { maps[$0]?.name } ?? "默认"
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("键位方案")
                Spacer()
                Menu(appID.flatMap { maps[$0]?.name } ?? "默认") {
                    Button("默认") { appID = nil }
                    ForEach(maps.keys.sorted(), id: \.self) { id in
                        Button(maps[id]?.name ?? id) { appID = id }
                    }
                    Divider()
                    Button("添加应用方案…") {
                        guard let app = pickApplication() else { return }
                        if maps[app.id] != nil {
                            appID = app.id
                            return
                        }
                        addingID = app.id
                        plugin.configure(.addApp(id: app.id, name: app.name), revision: state.revision)
                    }
                    if let appID, let revision = state.revision {
                        Button("移除当前应用方案…") {
                            cancelCapture()
                            protectInteraction(true)
                            deleting = (appID, revision)
                        }
                    }
                }.fixedSize().disabled(plugin.pending != nil).accessibilityIdentifier("remote.scope")
            }
            if state.frontApp.flatMap({ maps[$0] == nil ? nil : $0 }) != appID {
                Text("当前生效 · " + active).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setAction(_ value: RemoteAction?, key: RemoteButton, revision: UUID?) {
        plugin.configure(.action(app: appID, button: key, gesture: gesture, value: value), revision: revision)
    }

    private func pickApplication() -> (id: String, name: String, url: URL)? {
        cancelCapture()
        protectInteraction(true)
        defer { protectInteraction(false) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
            let id = bundle.bundleIdentifier
        else { return nil }
        return (id, url.deletingPathExtension().lastPathComponent, url)
    }

    private func choose(_ kind: RemoteAction.Kind, key: RemoteButton, revision: UUID?) {
        cancelCapture()
        if kind == .shortcut {
            beginCapture(revision)
            return
        }
        var action = RemoteAction(kind)
        if kind == .openApplication {
            guard let app = pickApplication() else { return }
            action.bundleID = app.id
            action.path = app.url.path
            action.label = app.name
        }
        setAction(action, key: key, revision: revision)
    }
}

extension RemoteButton {
    fileprivate var symbol: String {
        switch self {
        case .ok: "circle.inset.filled"
        case .power: "power"
        case .voice: "mic"
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .back: "arrow.uturn.backward"
        case .home: "house"
        case .volumeUp: "plus"
        case .volumeDown: "minus"
        case .menu: "line.3.horizontal"
        case .tv: "tv"
        }
    }
}

private struct RemoteRowPressStyle: ButtonStyle {
    let pressing: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.blue : Color.primary)
            .onChange(of: configuration.isPressed) { _, down in pressing(down) }
            .onDisappear { pressing(false) }
    }
}
