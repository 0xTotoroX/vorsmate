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
    let protectInteraction: (Bool) -> Void
    @State private var recording: RemoteAction?

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
            }.buttonStyle(.plain).foregroundStyle(.tint).accessibilityIdentifier("remote.back")

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
        .onDisappear { cancelCapture() }
    }

    private var gestures: some View {
        Picker("手势", selection: $gesture) {
            ForEach(RemoteGesture.allCases) { Text($0.name).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
    }

    private func overview(_ state: RemoteEditorState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let face = plugin.face {
                    Image(nsImage: face).resizable().scaledToFit().frame(width: 32, height: 65).accessibilityHidden(
                        true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("遥控器").font(.title2.weight(.semibold))
                    Text("小米蓝牙遥控器 2 Pro").font(.callout)
                    Text(state.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            gestures
            VStack(spacing: 0) {
                ForEach(buttons) { key in
                    let value = key == .voice ? "按住说话" : state.profile.action(for: key, gesture: gesture).title
                    Button {
                        page = .detail(key)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: key.symbol).frame(width: 19).accessibilityHidden(true)
                            Text(key.name)
                            Spacer(minLength: 6)
                            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }.frame(minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(key.name)，\(value)").accessibilityIdentifier(
                        "remote.key.\(key.rawValue)")
                    if key != buttons.last { Divider() }
                }
            }
            Divider()
            Button {
                page = .detail(.ok)
            } label: {
                HStack {
                    Label("按位置选键", systemImage: "scope")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("remote.position")
        }
    }

    @ViewBuilder private func detail(_ key: RemoteButton, _ state: RemoteEditorState) -> some View {
        let selection = Binding<RemoteButton>(
            get: { key },
            set: { button in
                cancelCapture()
                page = .detail(button)
            })
        Menu {
            ForEach(buttons) { button in Button(button.name) { selection.wrappedValue = button } }
        } label: {
            Text(key.name).font(.title2.weight(.semibold))
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("选择实体键，\(key.name)")
        RemoteFace(selected: selection, image: plugin.face, scale: 0.22)
            .frame(maxWidth: .infinity).padding(.vertical, 2)
        if key == .voice {
            LabeledContent("按住说话", value: "MiRemoteV 2ch")
            Text(state.voice).font(.callout).foregroundStyle(.secondary)
            if state.profile.voiceFn { LabeledContent("同时发送", value: "Fn / 地球键") }
        } else {
            gestures
            let action = state.profile.action(for: key, gesture: gesture)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("动作")
                    Spacer()
                    Menu(action.kind.title) {
                        ForEach(RemoteAction.Kind.allCases, id: \.self) { kind in
                            Button(kind.title) { choose(kind, key: key, previous: action) }
                        }
                    }.fixedSize().accessibilityIdentifier("remote.action")
                }
                if let previous = recording {
                    Divider()
                    HStack {
                        KeyRecorder { captured in
                            guard recording != nil else { return }
                            cancelCapture()
                            plugin.change(key, gesture: gesture, previous: previous, action: captured)
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
                    Button("重新录入") { beginCapture(action) }.buttonStyle(.link).accessibilityIdentifier("remote.record")
                } else if action.kind == .openApplication {
                    LabeledContent("应用", value: action.title)
                    Button("更换应用…") { choose(.openApplication, key: key, previous: action) }.buttonStyle(.link)
                }
                if state.profile.buttons[key.rawValue]?.rapid == true {
                    Text("允许快速连按").font(.callout).foregroundStyle(.secondary)
                }
            }.disabled(plugin.pending != nil || state.problem != nil)
        }
    }

    private func beginCapture(_ action: RemoteAction) {
        protectInteraction(true)
        recording = action
    }

    private func cancelCapture() {
        if recording != nil {
            recording = nil
            protectInteraction(false)
        }
    }

    private func choose(_ kind: RemoteAction.Kind, key: RemoteButton, previous: RemoteAction) {
        cancelCapture()
        if kind == .shortcut {
            beginCapture(previous)
            return
        }
        var action = RemoteAction(kind)
        if kind == .openApplication {
            protectInteraction(true)
            defer { protectInteraction(false) }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else {
                return
            }
            action.bundleID = id
            action.path = url.path
            action.label = url.deletingPathExtension().lastPathComponent
        }
        plugin.change(key, gesture: gesture, previous: previous, action: action)
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
