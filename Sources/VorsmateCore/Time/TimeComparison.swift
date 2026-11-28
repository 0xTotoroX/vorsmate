// [INPUT]: 一个绝对时刻、本地时区、对比时区、Foundation 的公历与时区数据库。
// [OUTPUT]: 当地与可选海外参考时区的时间、日期、跨日关系、时差与夏令时当天滑杆范围。
// [POS]: 时间对照的纯换算；默认跟随系统时区，测试可注入，不修改系统设置。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum ComparisonZone: String, CaseIterable, Codable, Sendable, Identifiable {
    case pacific = "America/Los_Angeles"
    case eastern = "America/New_York"
    case london = "Europe/London"
    case tokyo = "Asia/Tokyo"
    case utc = "UTC"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .pacific: "美西"
        case .eastern: "美东"
        case .london: "伦敦"
        case .tokyo: "东京"
        case .utc: "UTC"
        }
    }

    public var timeZone: TimeZone {
        switch self {
        case .utc:
            TimeZone(secondsFromGMT: 0)!
        case .pacific, .eastern, .london, .tokyo:
            TimeZone(identifier: rawValue)!
        }
    }

    public func abbreviation(for instant: Date) -> String {
        // 系统缩写受语言环境影响，固定输出常见英文时区缩写以区分夏令时。
        switch self {
        case .pacific:
            timeZone.isDaylightSavingTime(for: instant) ? "PDT" : "PST"
        case .eastern:
            timeZone.isDaylightSavingTime(for: instant) ? "EDT" : "EST"
        case .london:
            timeZone.isDaylightSavingTime(for: instant) ? "BST" : "GMT"
        case .tokyo:
            "JST"
        case .utc:
            "UTC"
        }
    }
}

public enum ClockRegion: String, CaseIterable, Sendable {
    case local, pacific

    public func timeZone(localTimeZone: TimeZone = .autoupdatingCurrent) -> TimeZone {
        timeZone(localTimeZone: localTimeZone, comparisonZone: .pacific)
    }

    public func timeZone(
        localTimeZone: TimeZone = .autoupdatingCurrent,
        comparisonZone: ComparisonZone
    ) -> TimeZone {
        self == .local ? localTimeZone : comparisonZone.timeZone
    }

    public func calendar(localTimeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        calendar(localTimeZone: localTimeZone, comparisonZone: .pacific)
    }

    public func calendar(
        localTimeZone: TimeZone = .autoupdatingCurrent,
        comparisonZone: ComparisonZone
    ) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone(localTimeZone: localTimeZone, comparisonZone: comparisonZone)
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

    init(
        at instant: Date,
        region: ClockRegion,
        localTimeZone: TimeZone,
        comparisonZone: ComparisonZone = .pacific
    ) {
        let zone = region.timeZone(localTimeZone: localTimeZone, comparisonZone: comparisonZone)
        let parts = region.calendar(localTimeZone: localTimeZone, comparisonZone: comparisonZone).dateComponents(
            [.year, .month, .day, .hour, .minute], from: instant)
        year = parts.year!
        month = parts.month!
        day = parts.day!
        hour = parts.hour!
        minute = parts.minute!
        abbreviation =
            region == .pacific
            ? comparisonZone.abbreviation(for: instant)
            : (zone.abbreviation(for: instant) ?? "")
    }
}

public struct TimeComparison: Equatable, Sendable {
    public let local: ClockReading
    public let pacific: ClockReading
    public let comparisonZone: ComparisonZone
    public let differenceInSeconds: Int
    /// 对比时区日历日期相对当地日期的天数，按日历日期计算，不能拿两个时区的午夜相减。
    public let pacificDayDifference: Int
    public var differenceLabel: String {
        if differenceInSeconds == 0 { return "与\(comparisonZone.title)时间相同" }
        let hours = abs(differenceInSeconds) / 3600
        let minutes = abs(differenceInSeconds) % 3600 / 60
        let duration = minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
        return "当地\(differenceInSeconds > 0 ? "快" : "慢") \(duration)"
    }
    public var dayLabel: String {
        let name = comparisonZone.title
        switch pacificDayDifference {
        case -1: return "\(name)前一天"
        case 0: return "同一天"
        case 1: return "\(name)后一天"
        default: return "\(name) \(pacific.date)"
        }
    }

    public init(at instant: Date, localTimeZone: TimeZone = .autoupdatingCurrent) {
        self.init(at: instant, localTimeZone: localTimeZone, comparisonZone: .pacific)
    }

    public init(
        at instant: Date,
        localTimeZone: TimeZone = .autoupdatingCurrent,
        comparisonZone: ComparisonZone
    ) {
        self.comparisonZone = comparisonZone
        local = ClockReading(at: instant, region: .local, localTimeZone: localTimeZone, comparisonZone: comparisonZone)
        pacific = ClockReading(
            at: instant, region: .pacific, localTimeZone: localTimeZone, comparisonZone: comparisonZone)
        differenceInSeconds =
            localTimeZone.secondsFromGMT(for: instant)
            - comparisonZone.timeZone.secondsFromGMT(for: instant)
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

    public init(
        at instant: Date,
        region: ClockRegion,
        localTimeZone: TimeZone = .autoupdatingCurrent,
        comparisonZone: ComparisonZone = .pacific
    ) {
        interval = region.calendar(localTimeZone: localTimeZone, comparisonZone: comparisonZone)
            .dateInterval(of: .day, for: instant)!
    }

    public func minute(at instant: Date) -> Double {
        min(lastMinute, max(0, instant.timeIntervalSince(interval.start) / 60))
    }

    public func instant(at minute: Double) -> Date {
        // 用当天实际经过的分钟数，保留夏令时跳过 / 重复的一小时，不滑进隔天。
        interval.start.addingTimeInterval(min(lastMinute, max(0, minute.rounded())) * 60)
    }
}
