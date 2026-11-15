// [INPUT]: FanModel 实测状态、单项展开绑定与主线程内的 SwiftUI 模式提交。
// [OUTPUT]: 自动 / 均衡 / 增强 / 自定义四个并列选项，右侧保留实测读数。
// [POS]: 总览中的风扇模块；展开回显生效参数与预设，未授权时提供助手启用入口。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore

enum FanControlChoice: CaseIterable, Hashable {
    case automatic, balanced, enhanced, custom
    var title: String {
        switch self {
        case .automatic: "自动"
        case .balanced: "均衡"
        case .enhanced: "增强"
        case .custom: "自定义"
        }
    }
    init(profile: FanProfile) {
        switch profile.mode {
        case .system: self = .automatic
        case .fixed: self = .custom
        case .curve:
            switch profile.preset {
            case .balanced: self = .balanced
            case .cooling: self = .enhanced
            case nil: self = .custom
            }
        }
    }
    func profile(rpm: Double) -> FanProfile {
        switch self {
        case .automatic: FanProfile()
        case .balanced: FanCurvePreset.balanced.profile
        case .enhanced: FanCurvePreset.cooling.profile
        case .custom: FanProfile(mode: .fixed, rpm: rpm)
        }
    }
}

struct FanView: View {
    @ObservedObject var model: FanModel
    @Binding var expanded: Bool

    private var status: String {
        if model.needsApproval { return "等待授权" }
        if !model.helperEnabled { return "监控" }
        if !model.controlConfirmed { return "待确认" }
        let choices = model.snapshot.profiles.values.map { FanControlChoice(profile: $0) }
        if let choice = choices.first {
            return choices.allSatisfy { $0 == choice } ? choice.title : "分别设置"
        }
        return model.snapshot.fans.contains(where: { $0.hardwareMode == 1 }) ? "外部控制" : "自动"
    }
    private var reading: String {
        guard let first = model.snapshot.fans.first else { return "暂无读数" }
        let rpm = "\(Int(first.actualRPM).formatted()) RPM"
        return model.snapshot.temperature.map { "\(rpm) · \(Int($0))°C" } ?? rpm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: "风扇", symbol: "fan", status: status,
                    value: reading, expanded: expanded, pending: model.busy)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fans.expand")
            .accessibilityLabel("风扇")
            .accessibilityValue("\(reading)，\(status)，\(expanded ? "已展开" : "已收起")")
            .help(
                model.snapshot.controlTemperature.map { "核心热点温度；增强散热参考温度为 \(Int($0))°C，按持续升温调速。" }
                    ?? "核心热点温度。此 Mac 暂无已核验的增强参考温度，自动模式由系统控制。")
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.helperEnabled {
                        HStack {
                            Text(model.needsApproval ? "等待系统授权" : "监控中").foregroundStyle(.secondary)
                            Spacer()
                            Button(model.needsApproval ? "打开授权设置" : "启用调速") { model.installHelper() }
                        }
                    }
                    if let competitor = model.competingApp {
                        Text("\(competitor) 正在运行，调速前请先退出它。").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshot.fans) { fan in
                        FanControlRow(model: model, fan: fan)
                            .disabled(
                                !model.helperEnabled || !model.controlConfirmed || model.busy
                                    || model.competingApp != nil)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let message = model.error ?? model.snapshot.message {
                Text(message).font(.callout)
                    .foregroundStyle(message == model.snapshot.safetyPause?.message ? .secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }
}

private struct FanControlRow: View {
    @ObservedObject var model: FanModel
    let fan: FanReading
    @State private var rpm = 2000.0
    private var current: FanProfile { model.snapshot.profiles[fan.id] ?? FanProfile() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.snapshot.fans.count > 1 { Text("风扇 \(fan.id + 1)") }
                // 显式闭包避免 Swift 6.3 将主线程方法转为 Binding setter 时崩溃。
                Picker(
                    "风扇 \(fan.id + 1) 模式",
                    selection: Binding(get: { FanControlChoice(profile: current) }, set: { setChoice($0) })
                ) {
                    ForEach(FanControlChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }.labelsHidden().pickerStyle(.segmented)
                    .accessibilityIdentifier("fans.mode.\(fan.id)")
                    .help("自动：系统调速。均衡：温和增加散热。增强：更早、更强地散热。自定义：固定转速。均衡和增强降温后交还系统，选择会保留。")
                // 操作反馈统一在摘要行显示，分段控件不随处理中状态改变宽度。
            }
            if current.mode == .fixed, fan.hasValidRange {
                HStack {
                    Slider(
                        value: $rpm, in: max(500, fan.minimumRPM)...fan.maximumRPM, step: 100,
                        onEditingChanged: { editing in
                            if !editing { model.configure(id: fan.id, profile: FanProfile(mode: .fixed, rpm: rpm)) }
                        }
                    ).accessibilityLabel("风扇 \(fan.id + 1) 目标转速")
                    Text("\(Int(rpm)) RPM").monospacedDigit().frame(width: 82, alignment: .trailing)
                }
            } else if current.mode == .curve, current.preset == nil {
                HStack {
                    Text("温控 \(Int(current.rampStart))–\(Int(current.fullSpeed))°C").font(.callout).foregroundStyle(
                        .secondary)
                    Spacer()
                    Button("设置固定转速") { setChoice(.custom) }
                }
            } else if fan.hardwareMode == 1, current.mode == .system {
                HStack {
                    Text("当前为外部手动转速").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复自动") { setChoice(.automatic) }
                }
            }
        }.onAppear {
            rpm =
                current.mode == .fixed
                ? current.rpm
                : min(fan.maximumRPM, max(max(500, fan.minimumRPM), fan.actualRPM.rounded()))
        }
        .onChange(of: current) { _, value in
            if value.mode == .fixed { rpm = value.rpm }
        }
    }
    private func setChoice(_ choice: FanControlChoice) {
        model.configure(id: fan.id, profile: choice.profile(rpm: rpm))
    }
}
