// [INPUT]: FanModel 实测状态、单项展开绑定与主线程内的 SwiftUI 模式提交。
// [OUTPUT]: 自动 / 增强散热 / 固定；两档差异仅在悬停解释，右侧保留实测读数。
// [POS]: 总览中的风扇模块；展开回显生效参数与预设，未授权时提供助手启用入口。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore

struct FanView: View {
    @ObservedObject var model: FanModel
    @Binding var expanded: Bool

    private var status: String {
        if model.needsApproval { return "等待授权" }
        if !model.helperEnabled { return "监控" }
        if !model.controlConfirmed { return "待确认" }
        let modes = model.snapshot.profiles.values.map(\.mode)
        if let mode = modes.first {
            guard modes.allSatisfy({ $0 == mode }) else { return "分别设置" }
            switch mode {
            case .system: return "自动"
            case .fixed: return "固定"
            case .curve:
                let preset = model.snapshot.profiles.values.first?.preset
                guard model.snapshot.profiles.values.allSatisfy({ $0.preset == preset }) else { return "增强 · 分别设置" }
                return "增强 · \(preset?.title ?? "自定")"
            }
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
    @State private var preset: FanCurvePreset = .balanced
    private var current: FanProfile { model.snapshot.profiles[fan.id] ?? FanProfile() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.snapshot.fans.count > 1 { Text("风扇 \(fan.id + 1)") }
                // 显式闭包避免 Swift 6.3 将主线程方法转为 Binding setter 时崩溃。
                Picker("风扇 \(fan.id + 1) 模式", selection: Binding(get: { current.mode }, set: { setMode($0) })) {
                    Text("自动").tag(FanMode.system)
                    Text("增强散热").tag(FanMode.curve)
                    Text("固定").tag(FanMode.fixed)
                }.labelsHidden().pickerStyle(.segmented)
                    .help("自动：由 macOS 决定转速。增强散热：持续升温后提前加速，降温后交还系统。固定：保持指定转速。")
                if model.busy { ProgressView().controlSize(.small) }
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
            } else if current.mode == .curve {
                Picker(
                    "增强风格",
                    selection: Binding(
                        get: { current.preset ?? preset },
                        set: { value in
                            preset = value
                            model.configure(id: fan.id, profile: value.profile)
                        })
                ) {
                    ForEach(FanCurvePreset.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden().pickerStyle(.segmented)
                .accessibilityIdentifier("fans.preset.\(fan.id)")
                .help("均衡：持续发热约 8 秒后温和加速。强冷：约 4 秒后更早介入，同温度下转速更高。持续升温适度提前加速，降温后缓慢回落。")
            } else if fan.hardwareMode == 1, current.mode == .system {
                HStack {
                    Text("当前为外部手动转速").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复自动") { setMode(.system) }
                }
            }
        }.onAppear {
            rpm =
                current.mode == .fixed
                ? current.rpm
                : min(fan.maximumRPM, max(max(500, fan.minimumRPM), fan.actualRPM.rounded()))
            if let active = current.preset { preset = active }
        }
        .onChange(of: current) { _, value in
            if let active = value.preset { preset = active }
        }
    }
    private func setMode(_ mode: FanMode) {
        model.configure(id: fan.id, profile: mode == .curve ? preset.profile : FanProfile(mode: mode, rpm: rpm))
    }
}
