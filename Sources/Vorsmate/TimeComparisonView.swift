// [INPUT]: 面板可见状态、单项展开绑定、系统时钟 / 时区变化与 TimeComparison。
// [OUTPUT]: 紧凑双时钟，按需展开当天滑杆 / 日期编辑，关闭面板恢复现在。
// [POS]: 总览顶部的时间对齐工具；默认无滑杆、无嵌套玻璃卡片。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore

struct TimeComparisonView: View {
    @Binding var isExpanded: Bool
    let panelVisible: Bool
    @State private var selectedDate: Date?
    @State private var editingRegion = ClockRegion.local
    @State private var localTimeZone = TimeZone.current

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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            localTimeZone = .current
        }
    }

    private func content(at now: Date) -> some View {
        let date = selectedDate ?? now
        let value = TimeComparison(at: date, localTimeZone: localTimeZone)
        let day = LocalDayTimeline(at: date, timeZone: localTimeZone)
        return VStack(spacing: 8) {
            HStack(spacing: 18) {
                clock("当地", reading: value.local, region: .local)
                Divider().frame(height: 42)
                clock("美西 · \(value.pacific.abbreviation)", reading: value.pacific, region: .pacific)
            }
            HStack(spacing: 8) {
                Text(value.differenceLabel)
                Spacer(minLength: 4)
                if value.pacificDayDifference != 0 { Text(value.dayLabel) }
                if isExpanded || selectedDate != nil {
                    Button("现在") {
                        selectedDate = nil
                        isExpanded = false
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedDate == nil)
                    .accessibilityIdentifier("time.now")
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            if isExpanded {
                dateEditor(region: editingRegion, date: date)
                HStack(spacing: 10) {
                    Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(
                        value: Binding(
                            get: {
                                day.minute(at: date)
                            },
                            set: { minute in
                                selectedDate = day.instant(at: minute)
                            }), in: 0...day.lastMinute
                    )
                    .accessibilityLabel("对齐当地当天时间")
                    .accessibilityValue("当地 \(value.local.time)，美西 \(value.pacific.time)，\(value.dayLabel)")
                    .accessibilityIdentifier("time.slider")
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 12)
    }

    private func clock(_ title: String, reading: ClockReading, region: ClockRegion) -> some View {
        Button {
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
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("对齐\(title)日期和时间")
        .accessibilityLabel("编辑\(title)时间")
        .accessibilityValue("\(reading.date) \(reading.time)")
        .accessibilityIdentifier("time.\(region.rawValue)")
    }

    private func dateEditor(region: ClockRegion, date: Date) -> some View {
        let title = region == .local ? "当地" : "美西"
        return VStack(spacing: 8) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                DatePicker(
                    "日期和时间", selection: Binding(get: { selectedDate ?? date }, set: { selectedDate = $0 }),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden().datePickerStyle(.field)
                .environment(\.timeZone, region.timeZone(localTimeZone: localTimeZone))
                .environment(\.calendar, region.calendar(localTimeZone: localTimeZone))
                .environment(\.locale, Locale(identifier: "zh-CN-u-hc-h23"))
                .accessibilityLabel(title + "日期和时间")
            }
            HStack {
                Button("前一天") { shiftDay(-1, date: date, region: region) }
                Button("后一天") { shiftDay(1, date: date, region: region) }
                Spacer()
                Button("完成") { isExpanded = false }.accessibilityIdentifier("time.done")
            }
        }.padding(.top, 6)
    }

    private func shiftDay(_ amount: Int, date: Date, region: ClockRegion) {
        selectedDate = region.calendar(localTimeZone: localTimeZone).date(
            byAdding: .day, value: amount, to: selectedDate ?? date)
    }
}
