// [INPUT]: 实际插件配置、当前实体键和所选手势。
// [OUTPUT]: 实体键点选、快捷键录入、动作编辑和独立验收输入框。
// [POS]: 原生键位窗口；预览只写内存，运行时写入本插件配置。
import AppKit
import SwiftUI
import VorsmateCore

extension RemoteAction.Kind {
    var title: String {
        switch self {
        case .none: "无动作"
        case .typeless: "切换 Typeless 听写"
        case .shortcut: "录入快捷键…"
        case .openApplication: "打开应用…"
        case .volumeUp: "增大音量"
        case .volumeDown: "减小音量"
        case .mute: "静音"
        case .playPause: "播放 / 暂停"
        case .previousTrack: "上一首"
        case .nextTrack: "下一首"
        }
    }
}
extension RemoteAction {
    var title: String {
        if kind == .openApplication { return label ?? "打开应用" }
        guard kind == .shortcut else { return kind.title }
        return RemoteModifier.display(code: keyCode ?? 0, flags: flags ?? 0, label: label)
    }
}

struct RemoteWindow: View {
    @ObservedObject var monitor: RemoteMonitor
    let preview: Bool
    let verify: Bool
    @State private var button = RemoteButton.ok
    @State private var recording: RemoteGesture?
    @State private var draft = ""
    @FocusState private var editing: Bool

    private func select(_ kind: RemoteAction.Kind, for gesture: RemoteGesture) {
        if kind == .shortcut {
            recording = gesture
            return
        }
        var action = RemoteAction(kind)
        if kind == .openApplication {
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
        monitor.edit(button, gesture: gesture, action: action)
    }
    private func record(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
    var body: some View {
        HStack(spacing: 0) {
            RemoteFace(selected: $button).padding(.horizontal, 36)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("小米蓝牙遥控器 2 Pro").foregroundStyle(.secondary)
                Picker("实体键", selection: $button) {
                    ForEach(RemoteButton.allCases) { Text($0.name).tag($0) }
                }.labelsHidden().fixedSize().accessibilityLabel("实体键")
                if button == .voice {
                    if !preview { Text(monitor.voiceStatus).foregroundStyle(.secondary) }
                    LabeledContent("按住说话", value: "MiRemoteV 2ch")
                    if monitor.profile.voiceFn { LabeledContent("同时发送", value: "Fn / 地球键") }
                } else {
                    let binding = monitor.profile.buttons[button.rawValue] ?? RemoteBinding()
                    ForEach(RemoteGesture.allCases) { gesture in
                        LabeledContent(gesture.name) {
                            Menu(binding[gesture].title) {
                                ForEach(RemoteAction.Kind.allCases, id: \.self) { kind in
                                    Button(kind.title) { select(kind, for: gesture) }
                                }
                            }.fixedSize().accessibilityLabel("\(gesture.name)，\(binding[gesture].title)")
                        }
                    }
                    if binding.rapid { Text("允许快速连按").font(.callout).foregroundStyle(.secondary) }
                }
                Divider()
                Text(monitor.feedback ?? (preview ? "预览" : monitor.status)).foregroundStyle(.secondary)
                if monitor.needsPermission && !preview { Button("打开输入监控设置") { monitor.requestAccess() } }
                if !preview && !CGPreflightPostEventAccess() {
                    Button("允许发送系统按键") {
                        _ = CGRequestPostEventAccess()
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if verify {
                    Text(monitor.voiceStatus).font(.callout)
                    Text(monitor.lastGesture ?? "验收输入框").font(.headline)
                    TextEditor(text: $draft).font(.body).frame(height: 52).border(.quaternary).focused($editing)
                    Text("已发送 \(monitor.sent) 次 · 当前换行 \(draft.filter { $0 == "\n" }.count) 个").font(
                        .callout.monospacedDigit())
                }
            }.frame(width: 282).padding(26)
        }.padding(.vertical, 14).fixedSize()
            .sheet(item: $recording) { gesture in
                VStack(alignment: .leading, spacing: 14) {
                    Text("录入\(button.name)的\(gesture.name)快捷键").font(.headline)
                    KeyRecorder { action in
                        monitor.edit(button, gesture: gesture, action: action)
                        recording = nil
                    }.frame(width: 250, height: 28)
                    Button("取消") { recording = nil }
                }.padding(22)
            }
            .onAppear { if verify { editing = true } }
            .onChange(of: monitor.sent) { _, count in
                if verify { record("actionReceipts=\(count) \(monitor.lastGesture ?? "")") }
            }
            .onChange(of: draft.filter { $0 == "\n" }.count) { _, count in if verify { record("lineBreaks=\(count)") } }
    }
}

private struct KeyRecorder: NSViewRepresentable {
    let capture: (RemoteAction) -> Void
    func makeNSView(context: Context) -> Field {
        let field = Field(labelWithString: "请按下快捷键")
        field.capture = capture
        return field
    }
    func updateNSView(_ nsView: Field, context: Context) { nsView.capture = capture }
    final class Field: NSTextField {
        var capture: ((RemoteAction) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                DispatchQueue.main.async { [weak self, weak window] in if let self { window?.makeFirstResponder(self) }
                }
            }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }
        private var held = [RemoteModifier]()
        private var chord = [RemoteModifier]()
        private var completed = false
        override func flagsChanged(with event: NSEvent) {
            guard !completed, let key = RemoteModifier.all.first(where: { $0.code == event.keyCode }) else { return }
            let bits = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            if bits & key.bit != 0 {
                if !held.contains(key) { held.append(key) }
                chord = held
            } else if held.contains(key) {
                held.removeAll { $0 == key }
                if held.isEmpty, let last = chord.last {
                    var action = RemoteAction(.shortcut)
                    action.keyCode = last.code
                    action.flags = RemoteModifier.flags(Array(chord.dropLast()))
                    action.label = last.title
                    completed = true
                    capture?(action)
                }
            }
        }
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat, !completed else { return }
            completed = true
            var action = RemoteAction(.shortcut)
            action.keyCode = event.keyCode
            action.flags = (event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)) & 0x00ff_ffff
            let special: [UInt16: String] = [
                36: "回车", 48: "Tab", 49: "空格", 51: "退格", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
            ]
            let character = event.charactersIgnoringModifiers?.uppercased() ?? ""
            action.label = special[event.keyCode] ?? (character.isEmpty ? "键码 \(event.keyCode)" : character)
            capture?(action)
        }
    }
}
