// [INPUT]: TranslationModel 状态、PanelSummaryRow、双引擎与预设配置及键盘录制回调。
// [OUTPUT]: 菜单栏总览中的「截图」摘要行、胶囊主操作按钮与单层同心圆角设置卡片。
// [POS]: PanelView 内可选「截图」子视图；默认不展开，编辑接口参数与录制快捷键时保护弹层不被误关。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import SwiftUI
import VorsmateCore

struct TranslationSectionView: View {
    @ObservedObject var model: TranslationModel
    @Binding var expanded: Bool
    var protectInteraction: (Bool) -> Void

    private enum EditingField: Hashable {
        case baseURL
        case model
        case apiKey
    }

    @State private var recordingShortcut = false
    @State private var recordingMessage: String?
    @State private var apiKeyInput = ""
    @FocusState private var editingField: EditingField?
    @Environment(\.panelRowHorizontalPadding) private var horizontalPadding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: PluginID.translate.title,
                    symbol: PluginID.translate.symbol,
                    status: model.statusText,
                    value: model.preferences.screenshotShortcut.displayTitle,
                    navigation: .disclosure(expanded: expanded),
                    pending: model.busy || model.translating || model.ocrRunning
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("translate.expand")
            .accessibilityLabel(PluginID.translate.title)
            .accessibilityValue("\(model.statusText)，\(expanded ? "已展开" : "已收起")")

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        model.triggerScreenshot()
                    } label: {
                        Label("开始截图", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .disabled(model.busy)
                    .accessibilityIdentifier("translate.screenshot")

                    settingsGroup
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 12)
                .onDisappear { stopAllEditing() }
            }

            if let conflict = model.hotKeyConflict {
                PanelInlineNotice(text: conflict, isError: true)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("translate.conflict")
            } else if model.feedbackIsError, let message = model.feedbackMessage {
                VStack(alignment: .leading, spacing: 6) {
                    PanelInlineNotice(text: message, isError: true)
                    if model.needsScreenCapturePermission {
                        Button("打开录屏设置") { model.openScreenCaptureSettings() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("translate.openScreenCaptureSettings")
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 12)
                .accessibilityIdentifier("translate.error")
            }
        }
        .onChange(of: expanded) { _, isExpanded in
            if !isExpanded { stopAllEditing() }
        }
        .onChange(of: editingField) { _, _ in
            syncInteractionProtection()
        }
        .onChange(of: recordingShortcut) { _, _ in
            syncInteractionProtection()
        }
        .onChange(of: model.preferences.apiConfig.baseURL) { _, _ in
            apiKeyInput = ""
        }
    }

    private var settingsGroup: some View {
        PanelInlineCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                shortcutRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider().padding(.horizontal, 12)

                engineRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider().padding(.horizontal, 12)

                targetLanguageRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("快捷键")
                    .font(.callout)
                Spacer(minLength: 8)
                if recordingShortcut {
                    TranslationShortcutRecorder(
                        onCapture: { captured in
                            recordingMessage = nil
                            recordingShortcut = false
                            var next = model.preferences
                            next.screenshotShortcut = captured
                            model.updatePreferences(next)
                        },
                        onInvalid: { message in
                            recordingMessage = message
                        },
                        onCancel: {
                            recordingMessage = nil
                            recordingShortcut = false
                        }
                    )
                    .frame(width: 112, height: 24)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                    )

                    Button("取消") {
                        recordingMessage = nil
                        recordingShortcut = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    let shortcut = model.preferences.screenshotShortcut
                    Button {
                        recordingMessage = nil
                        recordingShortcut = true
                    } label: {
                        Text(shortcut.displayTitle)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(shortcut.enabled && shortcut.isValid ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("点击录制截图快捷键")
                    .accessibilityIdentifier("translate.screenshotShortcut.edit")

                    if shortcut.enabled && shortcut.isValid {
                        Button {
                            recordingMessage = nil
                            var next = model.preferences
                            next.screenshotShortcut.enabled = false
                            model.updatePreferences(next)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清除快捷键")
                        .accessibilityLabel("清除快捷键")
                        .accessibilityIdentifier("translate.screenshotShortcut.clear")
                    }
                }
            }

            if let recordingMessage {
                Text(recordingMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var engineRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("翻译引擎")
                    .font(.callout)
                Spacer(minLength: 8)
                Picker(
                    "翻译引擎",
                    selection: Binding(
                        get: { model.preferences.engine },
                        set: { model.switchEngine($0) })
                ) {
                    ForEach(TranslationEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("translate.engine")
            }

            if model.preferences.engine == .openAICompatible {
                openAIConfigFields
            }
        }
    }

    private var openAIConfigFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(OpenAIProviderPreset.allCases) { preset in
                    let isSelected = model.preferences.apiConfig == preset.config
                    Button {
                        model.applyProviderPreset(preset)
                    } label: {
                        Text(preset.title)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("translate.preset.\(preset.rawValue)")
                }
                Spacer(minLength: 0)
            }

            TextField(
                "接口地址（例如 https://api.deepseek.com）",
                text: Binding(
                    get: { model.preferences.apiConfig.baseURL },
                    set: { value in
                        var next = model.preferences
                        next.apiConfig.baseURL = value
                        model.updatePreferences(next)
                    })
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .focused($editingField, equals: .baseURL)
            .accessibilityIdentifier("translate.api.baseURL")

            TextField(
                "模型名称（例如 deepseek-chat）",
                text: Binding(
                    get: { model.preferences.apiConfig.model },
                    set: { value in
                        var next = model.preferences
                        next.apiConfig.model = value
                        model.updatePreferences(next)
                    })
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .focused($editingField, equals: .model)
            .accessibilityIdentifier("translate.api.model")

            HStack(spacing: 6) {
                SecureField(
                    model.hasAPIKey
                        ? "输入新 API Key 覆盖"
                        : (model.apiKeyRequired ? "输入 API Key" : "可选（本地服务无需密钥）"),
                    text: $apiKeyInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($editingField, equals: .apiKey)
                .accessibilityIdentifier("translate.api.key")

                Button("保存") {
                    if model.saveAPIKey(apiKeyInput) {
                        apiKeyInput = ""
                        editingField = nil
                    }
                }
                .controlSize(.small)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("translate.api.saveKey")

                if model.hasAPIKey {
                    Button("清除") {
                        model.deleteAPIKey()
                        apiKeyInput = ""
                        editingField = nil
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("translate.api.deleteKey")
                }
            }

            HStack(spacing: 6) {
                Text("钥匙串状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                let keyStatusText =
                    model.hasAPIKey
                    ? "已存钥匙串"
                    : (model.apiKeyRequired ? "未配置" : "本地免密钥")
                let keyStatusColor: Color =
                    (model.hasAPIKey || !model.apiKeyRequired) ? .secondary : .orange
                Text(keyStatusText)
                    .font(.caption)
                    .foregroundStyle(keyStatusColor)
                    .accessibilityIdentifier("translate.api.keyStatus")
            }
        }
    }

    private var targetLanguageRow: some View {
        HStack(spacing: 8) {
            Text("目标语种")
                .font(.callout)
            Spacer(minLength: 8)
            Picker(
                "目标语种",
                selection: Binding(
                    get: { model.preferences.targetLanguage },
                    set: { model.switchTargetLanguage($0) })
            ) {
                ForEach(TranslationTargetLanguage.allCases) { target in
                    Text(target.title).tag(target)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("translate.targetLanguage")
        }
    }

    private func syncInteractionProtection() {
        protectInteraction(recordingShortcut || editingField != nil)
    }

    private func stopAllEditing() {
        recordingShortcut = false
        recordingMessage = nil
        editingField = nil
        apiKeyInput = ""
        protectInteraction(false)
    }
}

private struct TranslationShortcutRecorder: NSViewRepresentable {
    let onCapture: (TranslationShortcut) -> Void
    let onInvalid: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField(labelWithString: "请按下组合键")
        field.alignment = .center
        field.font = .systemFont(ofSize: 12)
        field.onCapture = onCapture
        field.onInvalid = onInvalid
        field.onCancel = onCancel
        return field
    }

    func updateNSView(_ nsView: RecorderField, context: Context) {
        nsView.onCapture = onCapture
        nsView.onInvalid = onInvalid
        nsView.onCancel = onCancel
    }

    final class RecorderField: NSTextField {
        var onCapture: ((TranslationShortcut) -> Void)?
        var onInvalid: ((String) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                DispatchQueue.main.async { [weak self, weak window] in
                    if let self { window?.makeFirstResponder(self) }
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

        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            let relevantFlags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if event.keyCode == 53 && relevantFlags.isEmpty {
                onCancel?()
                return
            }
            let special: [UInt16: String] = [
                36: "回车", 48: "Tab", 49: "空格", 51: "退格",
                123: "←", 124: "→", 125: "↓", 126: "↑",
                122: "F1", 120: "F2", 99: "F3", 118: "F4",
                96: "F5", 97: "F6", 98: "F7", 100: "F8",
                101: "F9", 109: "F10", 103: "F11", 111: "F12",
            ]
            let rawChar = event.charactersIgnoringModifiers?.uppercased() ?? ""
            let label = special[event.keyCode] ?? rawChar
            guard
                let shortcut = TranslationShortcut.from(
                    keyCode: event.keyCode, appKitModifierFlagsRaw: relevantFlags.rawValue, label: label)
            else {
                onInvalid?("请包含 ⌘ / ⌥ / ⌃ / ⇧ 修饰键")
                return
            }
            onCapture?(shortcut)
        }
    }
}
