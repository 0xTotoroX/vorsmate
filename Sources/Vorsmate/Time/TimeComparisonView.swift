// [INPUT]: 面板可见状态、单项展开绑定、交互保护回调、系统时钟／时区变化与 TimeComparison。
// [OUTPUT]: 紧凑双时钟，按需展开单层内联卡片内的日期编辑器、对比时区切换与当天滑杆，关闭面板恢复现在。
// [POS]: 总览顶部的时间对齐工具；默认无滑杆、无嵌套玻璃卡片。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore

struct TimeComparisonView: View {
    @Binding var isExpanded: Bool
    let panelVisible: Bool
    var protectInteraction: (Bool) -> Void = { _ in }

    @AppStorage("vorsmate.time.comparisonZone") private var comparisonZoneRaw = ComparisonZone.pacific.rawValue
    @State private var selectedDate: Date?
    @State private var editingRegion = ClockRegion.local
    @State private var localTimeZone = TimeZone.current
    @FocusState private var dateFocused: Bool
    @Environment(\.panelRowHorizontalPadding) private var horizontalPadding

    private var comparisonZone: ComparisonZone {
        ComparisonZone(rawValue: comparisonZoneRaw) ?? .pacific
    }

    var body: some View {
        Group {
            if panelVisible {
                TimelineView(.everyMinute) { content(at: $0.date) }
            } else {
                content(at: Date())
            }
        }
        .onChange(of: panelVisible) { _, visible in
            if !visible {
                selectedDate = nil
                editingRegion = .local
                dateFocused = false
                protectInteraction(false)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                dateFocused = false
                protectInteraction(false)
            }
        }
        .onChange(of: dateFocused) { _, focused in
            protectInteraction(focused && isExpanded)
        }
        .onDisappear {
            dateFocused = false
            protectInteraction(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            localTimeZone = .current
        }
    }

    private func content(at now: Date) -> some View {
        let date = selectedDate ?? now
        let value = TimeComparison(at: date, localTimeZone: localTimeZone, comparisonZone: comparisonZone)
        let day = LocalDayTimeline(
            at: date, region: editingRegion, localTimeZone: localTimeZone, comparisonZone: comparisonZone)
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                clock("当地", reading: value.local, region: .local)
                Divider().frame(height: 42)
                clock(
                    "\(comparisonZone.title) · \(value.pacific.abbreviation)", reading: value.pacific, region: .pacific)
            }
            HStack(spacing: 8) {
                Text(value.differenceLabel)
                Spacer(minLength: 4)
                if value.pacificDayDifference != 0 { Text(value.dayLabel) }
                if selectedDate != nil {
                    Button("现在") {
                        selectedDate = nil
                        isExpanded = false
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("time.now")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            if isExpanded {
                PanelInlineCard {
                    VStack(spacing: 10) {
                        dateEditor(region: editingRegion, date: date)
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Slider(
                                value: Binding(
                                    get: {
                                        day.minute(at: date)
                                    },
                                    set: { minute in
                                        selectedDate = day.instant(at: minute)
                                    }), in: 0...day.lastMinute
                            )
                            .accessibilityLabel("对齐\(editingRegion == .local ? "当地" : comparisonZone.title)当天时间")
                            .accessibilityValue(
                                "当地 \(value.local.time)，\(comparisonZone.title) \(value.pacific.time)，\(value.dayLabel)"
                            )
                            .accessibilityIdentifier("time.slider")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private func clock(_ title: String, reading: ClockReading, region: ClockRegion) -> some View {
        let active = isExpanded && editingRegion == region
        return Button {
            if isExpanded, editingRegion == region {
                isExpanded = false
            } else {
                editingRegion = region
                isExpanded = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(reading.time).font(.system(size: 26, weight: .medium)).monospacedDigit()
                Text("\(reading.month)月\(reading.day)日").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                active ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.32) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("对齐\(title)日期和时间")
        .accessibilityLabel("编辑\(title)时间")
        .accessibilityValue("\(reading.date) \(reading.time)")
        .accessibilityIdentifier("time.\(region.rawValue)")
    }

    private func dateEditor(region: ClockRegion, date: Date) -> some View {
        let title = region == .local ? "当地" : comparisonZone.title
        let zone = region.timeZone(localTimeZone: localTimeZone, comparisonZone: comparisonZone)
        let cal = region.calendar(localTimeZone: localTimeZone, comparisonZone: comparisonZone)
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                if region == .local {
                    Text("当地").font(.callout)
                } else {
                    Picker("切换对比时区", selection: $comparisonZoneRaw) {
                        ForEach(ComparisonZone.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("切换对比时区")
                    .accessibilityIdentifier("time.zone")
                }

                Spacer(minLength: 4)
                DatePicker(
                    "日期和时间",
                    selection: Binding(get: { selectedDate ?? date }, set: { selectedDate = $0 }),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.field)
                .focused($dateFocused)
                .environment(\.timeZone, zone)
                .environment(\.calendar, cal)
                .environment(\.locale, Locale(identifier: "zh-CN-u-hc-h23"))
                .accessibilityLabel(title + "日期和时间")
            }
            HStack {
                Button("前一天") { shiftDay(-1, date: date, region: region) }
                Button("后一天") { shiftDay(1, date: date, region: region) }
                Spacer()
                Button("完成") { isExpanded = false }.accessibilityIdentifier("time.done")
            }
        }
    }

    private func shiftDay(_ amount: Int, date: Date, region: ClockRegion) {
        selectedDate = region.calendar(localTimeZone: localTimeZone, comparisonZone: comparisonZone).date(
            byAdding: .day, value: amount, to: selectedDate ?? date)
    }
}
