// [INPUT]: UnattendedAuthController 状态与操作、面板最大高度与交互保护回调。
// [OUTPUT]: 总览单行摘要（含开启态内联关闭）与极简布局优先的 386 点详情页（开关、密码、可选截止与扁平活动记录）。
// [POS]: PanelView 内「无人值守授权」视图；以布局、图标和原生控件传达状态，绝不显示密码。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct UnattendedAuthSummary: View {
    @ObservedObject var controller: UnattendedAuthController
    let open: () -> Void
    @Environment(\.panelRowHorizontalPadding) private var horizontalPadding

    private var statusText: String {
        if controller.isEnabled {
            if let deadline = controller.deadline {
                return "至 \(UnattendedAuthStatusFormatter.deadlineClockText(deadline, now: controller.now))"
            }
            return "手动关闭"
        }
        if controller.passwordInvalidated { return "密码已失效" }
        if !controller.hasSavedPassword { return "未设密码" }
        return "关闭"
    }

    private var statusSymbol: String? {
        if controller.passwordInvalidated || (controller.isEnabled && !controller.accessibilityTrusted) {
            return "exclamationmark.triangle.fill"
        }
        if controller.isEnabled && controller.isScreenLocked {
            return "lock.fill"
        }
        return nil
    }

    private var statusColor: Color {
        if controller.passwordInvalidated || (controller.isEnabled && !controller.accessibilityTrusted) {
            return .red
        }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelActionSummaryRow(
                title: PluginID.unattendedAuth.title,
                symbol: controller.isEnabled ? "lock.shield.fill" : PluginID.unattendedAuth.symbol,
                symbolColor: controller.isEnabled ? Color.accentColor : Color.primary,
                status: statusText,
                statusSymbol: statusSymbol,
                statusColor: statusColor,
                value: controller.isEnabled
                    ? controller.deadline.map {
                        UnattendedAuthStatusFormatter.remainingText(until: $0, now: controller.now)
                    } : nil,
                summaryIdentifier: "unattendedAuth.summary",
                accessibilityLabel: PluginID.unattendedAuth.title,
                accessibilityValue: controller.isEnabled ? controller.fullStatusText : statusText,
                open: open
            ) {
                if controller.isEnabled {
                    Button("关闭") {
                        controller.disable(reason: .manual)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("关闭无人值守授权")
                    .accessibilityIdentifier("unattendedAuth.summary.disable")
                }
            }

            if controller.isEnabled && !controller.accessibilityTrusted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("辅助功能未授权")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("设置") { controller.openAccessibilitySettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                .font(.caption)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 10)
                .accessibilityIdentifier("unattendedAuth.summary.accessibilityAlert")
            } else if !controller.isEnabled,
                let notice = controller.errorMessage ?? controller.statusBannerMessage
            {
                let isAlert = controller.errorMessage != nil || controller.passwordInvalidated
                PanelInlineNotice(
                    text: notice,
                    symbol: isAlert ? "exclamationmark.triangle.fill" : "clock.badge.checkmark",
                    isError: isAlert
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 10)
                .accessibilityIdentifier("unattendedAuth.summary.notice")
            }
        }
    }
}

struct UnattendedAuthView: View {
    @ObservedObject var controller: UnattendedAuthController
    let maximumHeight: CGFloat
    var protectInteraction: (Bool) -> Void
    let back: () -> Void

    private enum DeadlineMode: Hashable {
        case none, duration, specificDate
    }

    private enum DurationPreset: Hashable {
        case minutes(Int)
        case custom

        var title: String {
            switch self {
            case .minutes(15): "15分"
            case .minutes(30): "30分"
            case .minutes(60): "1时"
            case .minutes(120): "2时"
            case .minutes(let value): "\(value)分"
            case .custom: "自定"
            }
        }
    }

    private enum FocusField: Hashable {
        case password
        case customMinutes
    }

    private static let durationPresets: [DurationPreset] = [
        .minutes(15), .minutes(30), .minutes(60), .minutes(120), .custom,
    ]

    @State private var passwordInput = ""
    @State private var editingPassword = false
    @State private var deadlineMode: DeadlineMode = .duration
    @State private var durationPreset: DurationPreset = .minutes(30)
    @State private var customMinutesText = "45"
    @State private var specificDeadline = Date().addingTimeInterval(30 * 60)
    @State private var headerHeight: CGFloat = 92
    @State private var bodyHeight: CGFloat = 180
    @FocusState private var focusedField: FocusField?

    private var parsedCustomMinutes: Int? {
        let trimmed = customMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...UnattendedAuthPolicy.maxCustomMinutes).contains(value) else {
            return nil
        }
        return value
    }

    private var selectedDeadlineChoice: UnattendedAuthDeadlineChoice {
        switch deadlineMode {
        case .none:
            return .none
        case .duration:
            switch durationPreset {
            case .minutes(let minutes): return .durationMinutes(minutes)
            case .custom: return .durationMinutes(parsedCustomMinutes ?? 0)
            }
        case .specificDate:
            return .specificDate(specificDeadline)
        }
    }

    private var isCustomDurationInvalid: Bool {
        deadlineMode == .duration && durationPreset == .custom && parsedCustomMinutes == nil
    }

    private var showsPasswordEditor: Bool {
        !controller.hasSavedPassword || controller.passwordInvalidated || editingPassword
    }

    private var canEnable: Bool {
        controller.hasSavedPassword
            && !controller.passwordInvalidated
            && controller.accessibilityTrusted
            && !isCustomDurationInvalid
    }

    private var needsInteractionProtection: Bool {
        focusedField != nil
            || editingPassword
            || (!controller.isEnabled && deadlineMode == .specificDate)
            || (!controller.hasSavedPassword && !passwordInput.isEmpty)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { next in
                if next {
                    _ = controller.enable(deadlineChoice: selectedDeadlineChoice)
                } else {
                    controller.disable(reason: .manual)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    ceil($0.size.height)
                } action: {
                    headerHeight = $0
                }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PanelSectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            if showsPasswordEditor {
                                passwordBar
                            }

                            if !controller.accessibilityTrusted {
                                accessibilityBar
                            }

                            if !controller.isEnabled {
                                deadlineBar
                            }

                            Text("已弹出的请求和「隐私与安全」请求由本人确认")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityIdentifier("unattendedAuth.scopeNotice")
                        }
                        .padding(14)
                    }

                    if let feedback = controller.errorMessage ?? controller.statusBannerMessage {
                        feedbackBar(
                            feedback,
                            isAlert: controller.errorMessage != nil || controller.passwordInvalidated
                        )
                        .padding(.horizontal, 4)
                    }

                    if controller.currentSession?.events.isEmpty == false || !controller.history.isEmpty {
                        PanelSectionCard {
                            activitySection
                                .padding(14)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) {
                    ceil($0.size.height)
                } action: {
                    bodyHeight = $0
                }
            }
            .scrollIndicators(.never)
            .frame(height: min(bodyHeight, max(64, maximumHeight - headerHeight)))
        }
        .onAppear {
            if specificDeadline <= controller.now.addingTimeInterval(60) {
                specificDeadline = controller.now.addingTimeInterval(30 * 60)
            }
            protectInteraction(needsInteractionProtection)
        }
        .onChange(of: needsInteractionProtection) { _, active in
            protectInteraction(active)
        }
        .onChange(of: deadlineMode) { _, mode in
            if mode == .specificDate && specificDeadline <= controller.now.addingTimeInterval(60) {
                specificDeadline = controller.now.addingTimeInterval(30 * 60)
            }
        }
        .onChange(of: controller.hasSavedPassword) { _, hasSaved in
            if !hasSaved {
                editingPassword = false
                passwordInput = ""
            }
        }
        .onDisappear {
            passwordInput = ""
            editingPassword = false
            focusedField = nil
            protectInteraction(false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) {
                    Label("Vorsmate", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("unattendedAuth.back")

                Spacer()

                if controller.hasSavedPassword {
                    Menu {
                        Button("更换密码") {
                            passwordInput = ""
                            editingPassword = true
                            focusedField = .password
                        }
                        .accessibilityIdentifier("unattendedAuth.replacePassword")

                        Button("删除密码", role: .destructive) {
                            controller.deletePassword()
                        }
                        .accessibilityIdentifier("unattendedAuth.deletePassword")
                    } label: {
                        Label(
                            controller.passwordInvalidated ? "密码失效" : "密码",
                            systemImage: controller.passwordInvalidated ? "key.slash.fill" : "key.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(controller.passwordInvalidated ? Color.red : Color.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(controller.passwordInvalidated ? "密码已失效，点击更新" : "管理员密码已存本机钥匙串")
                    .accessibilityLabel("管理员密码管理")
                    .accessibilityIdentifier("unattendedAuth.passwordMenu")
                }
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PluginID.unattendedAuth.title)
                        .font(.title2.weight(.semibold))

                    if controller.isEnabled {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            if let deadline = controller.deadline {
                                Text(
                                    "至 \(UnattendedAuthStatusFormatter.deadlineClockText(deadline, now: controller.now)) · \(UnattendedAuthStatusFormatter.remainingText(until: deadline, now: controller.now))"
                                )
                                .monospacedDigit()
                            } else {
                                Text("手动关闭")
                            }
                            if controller.isScreenLocked {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .help("屏幕已锁定")
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("unattendedAuth.headerStatus")
                    }
                }

                Spacer(minLength: 8)

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.isEnabled && !canEnable)
                    .accessibilityLabel(controller.isEnabled ? "关闭无人值守授权" : "开启无人值守授权")
                    .accessibilityIdentifier(controller.isEnabled ? "unattendedAuth.disable" : "unattendedAuth.enable")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    private var passwordBar: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.passwordInvalidated ? "key.slash.fill" : "key.fill")
                .font(.system(size: 13))
                .foregroundStyle(controller.passwordInvalidated ? Color.red : Color.secondary)
                .help("本机钥匙串加密保存，不上云、不写日志")

            SecureField(
                controller.hasSavedPassword ? "新管理员密码" : "管理员密码",
                text: $passwordInput
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .password)
            .onSubmit(submitPassword)
            .accessibilityIdentifier("unattendedAuth.passwordField")

            Button("保存", action: submitPassword)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(passwordInput.isEmpty)
                .accessibilityIdentifier("unattendedAuth.savePassword")

            if editingPassword && controller.hasSavedPassword && !controller.passwordInvalidated {
                Button {
                    passwordInput = ""
                    editingPassword = false
                    focusedField = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("取消")
                .accessibilityIdentifier("unattendedAuth.cancelReplacePassword")
            }
        }
    }

    private var accessibilityBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
            Text("辅助功能")
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
            Spacer()
            Button("授权") {
                controller.requestAccessibilityTrust()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("unattendedAuth.requestAccessibility")

            Button("系统设置") {
                controller.openAccessibilitySettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("unattendedAuth.openAccessibility")
        }
    }

    private var deadlineBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("截止", selection: $deadlineMode) {
                Text("不设截止").tag(DeadlineMode.none)
                Text("按时长").tag(DeadlineMode.duration)
                Text("指定时刻").tag(DeadlineMode.specificDate)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("unattendedAuth.deadlineMode")

            if deadlineMode == .duration {
                HStack(spacing: 6) {
                    ForEach(Self.durationPresets, id: \.self) { preset in
                        durationButton(for: preset)
                    }
                }
                if durationPreset == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField("45", text: $customMinutesText)
                                .textFieldStyle(.roundedBorder)
                                .monospacedDigit()
                                .frame(width: 68)
                                .focused($focusedField, equals: .customMinutes)
                                .accessibilityIdentifier("unattendedAuth.customMinutes")
                            Text("分钟")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        if isCustomDurationInvalid {
                            Text("请输入 1–\(UnattendedAuthPolicy.maxCustomMinutes) 之间的整数分钟")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("unattendedAuth.customMinutesError")
                        }
                    }
                }
            } else if deadlineMode == .specificDate {
                DatePicker(
                    "截止时刻",
                    selection: $specificDeadline,
                    in: controller.now.addingTimeInterval(60)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.field)
                .environment(\.locale, Locale(identifier: "zh-CN-u-hc-h23"))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("截止时刻")
                .accessibilityIdentifier("unattendedAuth.specificDate")
            }
        }
    }

    @ViewBuilder
    private func durationButton(for preset: DurationPreset) -> some View {
        let selected = durationPreset == preset
        Button {
            durationPreset = preset
            if preset == .custom { focusedField = .customMinutes }
        } label: {
            Text(preset.title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func feedbackBar(_ message: String, isAlert: Bool) -> some View {
        PanelInlineNotice(
            text: message,
            symbol: isAlert ? "exclamationmark.circle.fill" : "info.circle",
            isError: isAlert
        )
        .accessibilityIdentifier(isAlert ? "unattendedAuth.error" : "unattendedAuth.banner")
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("活动记录")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !controller.history.isEmpty {
                    Button {
                        controller.clearHistory()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空记录")
                    .accessibilityLabel("清空记录")
                    .accessibilityIdentifier("unattendedAuth.clearHistory")
                }
            }

            if let current = controller.currentSession, !current.events.isEmpty {
                sessionRow(current, isCurrent: true)
                if !controller.history.isEmpty { Divider() }
            }

            ForEach(Array(controller.history.enumerated()), id: \.element.id) { index, session in
                if index > 0 { Divider() }
                sessionRow(session, isCurrent: false)
            }
        }
    }

    private func sessionRow(_ session: UnattendedAuthSessionRecord, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isCurrent {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(UnattendedAuthDateFormatters.sessionTime(session.startedAt, relativeTo: controller.now))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                    Spacer()
                    Text(
                        session.deadline.map {
                            "至 \(UnattendedAuthStatusFormatter.deadlineClockText($0, now: controller.now))"
                        } ?? "手动关闭"
                    )
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                } else {
                    Text(sessionRangeText(session))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(session.stopReason?.title ?? "已结束")
                        .font(.caption)
                        .foregroundStyle(session.stopReason == .passwordInvalid ? Color.red : Color.secondary)
                }
            }

            ForEach(session.events) { event in
                eventRow(event)
            }
        }
    }

    private func eventRow(_ event: UnattendedAuthDialogEvent) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: outcomeSymbol(event.outcome))
                .font(.system(size: 11))
                .foregroundStyle(outcomeColor(event.outcome))
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
                .help(event.detail ?? event.outcome.title)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.source)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(UnattendedAuthDateFormatters.eventTime(event.timestamp))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(event.summary)
                if event.outcome != .approved {
                    Text(event.outcome.title)
                        .font(.caption2)
                        .foregroundStyle(outcomeColor(event.outcome))
                }
            }
        }
    }

    private func submitPassword() {
        let value = passwordInput
        if controller.savePassword(value) {
            passwordInput = ""
            editingPassword = false
            focusedField = nil
        }
    }

    private func sessionRangeText(_ session: UnattendedAuthSessionRecord) -> String {
        let start = UnattendedAuthDateFormatters.sessionTime(session.startedAt, relativeTo: controller.now)
        guard let endedAt = session.endedAt else { return start }
        let end = UnattendedAuthDateFormatters.sessionTime(endedAt, relativeTo: session.startedAt)
        return "\(start) – \(end)"
    }

    private func outcomeSymbol(_ outcome: UnattendedAuthEventOutcome) -> String {
        switch outcome {
        case .approved: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .leftForUser: "person.fill"
        case .passwordInvalid: "key.slash.fill"
        }
    }

    private func outcomeColor(_ outcome: UnattendedAuthEventOutcome) -> Color {
        switch outcome {
        case .approved: .green
        case .blocked: .orange
        case .leftForUser: .secondary
        case .passwordInvalid: .red
        }
    }
}

@MainActor
private enum UnattendedAuthDateFormatters {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func sessionTime(_ date: Date, relativeTo reference: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: reference) {
            return timeFormatter.string(from: date)
        }
        return monthDayTimeFormatter.string(from: date)
    }

    static func eventTime(_ date: Date) -> String {
        eventTimeFormatter.string(from: date)
    }
}
