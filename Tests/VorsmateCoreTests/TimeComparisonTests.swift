// [INPUT]: 绝对 UTC 时刻与 TimeComparison。
// [OUTPUT]: 当地 / 美西的跨时区、冬夏时差、跨日与夏令时当天滑杆验证。
// [POS]: 时间换算行为测试；不依赖当前日期或测试机器时区。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore

@Suite("当地与美西时间")
struct TimeComparisonTests {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test("冬季中国快16小时，美西上午9点对应中国次日1点")
    func winter() {
        let value = TimeComparison(at: instant("2026-11-09T17:00:00Z"), localTimeZone: zone)
        #expect(value.local.time == "01:00" && value.local.date == "2026-11-10")
        #expect(value.pacific.time == "09:00" && value.pacific.date == "2026-11-09")
        #expect(value.differenceInSeconds == 16 * 3600)
        #expect(value.pacific.abbreviation == "PST")
        #expect(value.pacificDayDifference == -1)
    }
    @Test("夏季中国快15小时，美西上午9点对应中国次日零点")
    func summer() {
        let value = TimeComparison(at: instant("2026-07-01T16:00:00Z"), localTimeZone: zone)
        #expect(value.local.time == "00:00" && value.local.date == "2026-07-02")
        #expect(value.pacific.time == "09:00" && value.pacific.date == "2026-07-01")
        #expect(value.differenceInSeconds == 15 * 3600)
        #expect(value.pacific.abbreviation == "PDT")
    }
    @Test("同日与跨年明确显示两地日期")
    func dates() {
        let sameDay = TimeComparison(at: instant("2026-11-09T10:00:00Z"), localTimeZone: zone)
        #expect(sameDay.local.time == "18:00" && sameDay.pacific.time == "02:00")
        #expect(sameDay.pacificDayDifference == 0)
        let newYear = TimeComparison(at: instant("2026-12-31T16:00:00Z"), localTimeZone: zone)
        #expect(newYear.local.date == "2027-01-01")
        #expect(newYear.pacific.date == "2026-12-31")
        #expect(newYear.pacificDayDifference == -1)
    }
    @Test("春季跳过02点，时差随所选时刻更新")
    func springForward() {
        let before = TimeComparison(at: instant("2026-03-08T09:59:00Z"), localTimeZone: zone)
        let after = TimeComparison(at: instant("2026-03-08T10:00:00Z"), localTimeZone: zone)
        #expect(before.pacific.time == "01:59" && before.differenceInSeconds == 16 * 3600)
        #expect(after.pacific.time == "03:00" && after.differenceInSeconds == 15 * 3600)
        #expect(before.local.time == "17:59" && after.local.time == "18:00")
    }
    @Test("秋季重复01点用PDT和PST区分，两次对应不同中国时间")
    func fallBack() {
        let first = TimeComparison(at: instant("2026-11-01T08:30:00Z"), localTimeZone: zone)
        let second = TimeComparison(at: instant("2026-11-01T09:30:00Z"), localTimeZone: zone)
        #expect(first.pacific.time == "01:30" && second.pacific.time == "01:30")
        #expect(first.pacific.abbreviation == "PDT" && second.pacific.abbreviation == "PST")
        #expect(first.local.time == "16:30" && second.local.time == "17:30")
    }
    @Test("本地时区支持非整点时差、落后美西和与美西相同")
    func differentLocalZones() {
        let date = instant("2026-11-09T17:00:00Z")
        let india = TimeComparison(at: date, localTimeZone: TimeZone(identifier: "Asia/Kolkata")!)
        #expect(india.local.time == "22:30")
        #expect(india.differenceLabel == "当地快 13 小时 30 分钟")
        let hawaii = TimeComparison(at: date, localTimeZone: TimeZone(identifier: "Pacific/Honolulu")!)
        #expect(hawaii.local.time == "07:00")
        #expect(hawaii.differenceLabel == "当地慢 2 小时")
        let same = TimeComparison(at: date, localTimeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(same.local.time == same.pacific.time && same.pacificDayDifference == 0)
        #expect(same.differenceLabel == "与美西时间相同")
    }
    @Test("本地与美西分别计算所选日期的夏令时")
    func independentDST() {
        let london = TimeZone(identifier: "Europe/London")!
        let march = TimeComparison(at: instant("2026-03-15T12:00:00Z"), localTimeZone: london)
        let july = TimeComparison(at: instant("2026-07-15T12:00:00Z"), localTimeZone: london)
        #expect(march.local.time == "12:00" && march.differenceInSeconds == 7 * 3600)
        #expect(july.local.time == "13:00" && july.differenceInSeconds == 8 * 3600)
    }
    @Test("时区变化重算本地时钟与日期，不改变绝对时刻和美西时间")
    func changedLocalZone() {
        let date = instant("2026-11-09T17:00:00Z")
        let first = TimeComparison(at: date, localTimeZone: zone)
        let second = TimeComparison(at: date, localTimeZone: TimeZone(identifier: "Europe/London")!)
        #expect(first.local.date == "2026-11-10" && second.local.date == "2026-11-09")
        #expect(first.pacific == second.pacific)
        #expect(second.local.time == "17:00" && second.differenceInSeconds == 8 * 3600)
    }
    @Test("本地春季滑杆跳过不存在的一小时，终点仍是当天23:59")
    func springDaySlider() {
        let zone = TimeZone(identifier: "America/New_York")!
        let day = LocalDayTimeline(at: instant("2026-03-08T12:00:00Z"), timeZone: zone)
        #expect(day.lastMinute == 23 * 60 - 1)
        let value = TimeComparison(at: day.instant(at: 120), localTimeZone: zone)
        #expect(value.local.time == "03:00")
        let end = TimeComparison(at: day.instant(at: 3000), localTimeZone: zone)
        #expect(end.local.date == "2026-03-08" && end.local.time == "23:59")
    }
    @Test("本地秋季滑杆保留两次01:30，终点不提前一小时")
    func fallDaySlider() {
        let zone = TimeZone(identifier: "America/New_York")!
        let day = LocalDayTimeline(at: instant("2026-11-01T12:00:00Z"), timeZone: zone)
        #expect(day.lastMinute == 25 * 60 - 1)
        let first = day.instant(at: 90)
        let second = day.instant(at: 150)
        #expect(TimeComparison(at: first, localTimeZone: zone).local.time == "01:30")
        #expect(TimeComparison(at: second, localTimeZone: zone).local.time == "01:30")
        #expect(second.timeIntervalSince(first) == 3600)
        #expect(day.minute(at: first) == 90 && day.minute(at: second) == 150)
        let end = TimeComparison(at: day.instant(at: day.lastMinute), localTimeZone: zone)
        #expect(end.local.date == "2026-11-01" && end.local.time == "23:59")
    }
}
