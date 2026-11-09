// [INPUT]: 一个绝对时刻、本地时区、Foundation 的公历与时区数据库。
// [OUTPUT]: 当地 / 美西的时间、日期、跨日关系、时差与夏令时当天滑杆范围。
// [POS]: 时间对照的纯换算；默认跟随系统时区，测试可注入，不修改系统设置。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum ClockRegion: String, CaseIterable, Sendable {
    case local, pacific
    public func timeZone(localTimeZone: TimeZone = .autoupdatingCurrent) -> TimeZone {
        self == .local ? localTimeZone : TimeZone(identifier: "America/Los_Angeles")!
    }
    public func calendar(localTimeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone(localTimeZone: localTimeZone)
        return value
    }
}

public struct ClockReading: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let abbreviation: String
    public var time: String { String(format: "%02d:%02d", hour, minute) }
    public var date: String { String(format: "%04d-%02d-%02d", year, month, day) }

    init(at instant: Date, region: ClockRegion, localTimeZone: TimeZone) {
        let zone = region.timeZone(localTimeZone: localTimeZone)
        let parts = region.calendar(localTimeZone: localTimeZone).dateComponents(
            [.year, .month, .day, .hour, .minute], from: instant)
        year = parts.year!
        month = parts.month!
        day = parts.day!
        hour = parts.hour!
        minute = parts.minute!
        // 系统缩写受语言影响，中文环境可能返回 GMT-7 / GMT-8；美西标签固定区分 PST / PDT。
        abbreviation =
            region == .pacific
            ? (zone.isDaylightSavingTime(for: instant) ? "PDT" : "PST")
            : (zone.abbreviation(for: instant) ?? "")
    }
}

public struct TimeComparison: Equatable, Sendable {
    public let local: ClockReading
    public let pacific: ClockReading
    public let differenceInSeconds: Int
    /// 美西日历日期相对当地日期的天数，按日历日期计算，不能拿两个时区的午夜相减。
    public let pacificDayDifference: Int
    public var differenceLabel: String {
        if differenceInSeconds == 0 { return "与美西时间相同" }
        let hours = abs(differenceInSeconds) / 3600
        let minutes = abs(differenceInSeconds) % 3600 / 60
        let duration = minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
        return "当地\(differenceInSeconds > 0 ? "快" : "慢") \(duration)"
    }
    public var dayLabel: String {
        switch pacificDayDifference {
        case -1: "美西前一天"
        case 0: "同一天"
        case 1: "美西后一天"
        default: "美西 \(pacific.date)"
        }
    }

    public init(at instant: Date, localTimeZone: TimeZone = .autoupdatingCurrent) {
        local = ClockReading(at: instant, region: .local, localTimeZone: localTimeZone)
        pacific = ClockReading(at: instant, region: .pacific, localTimeZone: localTimeZone)
        differenceInSeconds =
            localTimeZone.secondsFromGMT(for: instant)
            - ClockRegion.pacific.timeZone().secondsFromGMT(for: instant)
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = TimeZone(secondsFromGMT: 0)!
        let localDay = civil.date(from: DateComponents(year: local.year, month: local.month, day: local.day))!
        let pacificDay = civil.date(from: DateComponents(year: pacific.year, month: pacific.month, day: pacific.day))!
        pacificDayDifference = civil.dateComponents([.day], from: localDay, to: pacificDay).day!
    }
}

public struct LocalDayTimeline: Sendable {
    private let interval: DateInterval
    public var lastMinute: Double { interval.duration / 60 - 1 }

    public init(at instant: Date, timeZone: TimeZone = .autoupdatingCurrent) {
        interval = ClockRegion.local.calendar(localTimeZone: timeZone).dateInterval(of: .day, for: instant)!
    }
    public func minute(at instant: Date) -> Double {
        min(lastMinute, max(0, instant.timeIntervalSince(interval.start) / 60))
    }
    public func instant(at minute: Double) -> Date {
        // 用当天实际经过的分钟数，保留夏令时跳过 / 重复的一小时，不滑进隔天。
        interval.start.addingTimeInterval(min(lastMinute, max(0, minute.rounded())) * 60)
    }
}
