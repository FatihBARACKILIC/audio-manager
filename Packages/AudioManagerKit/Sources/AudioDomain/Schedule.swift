import Foundation

/// Wall-clock time of day, independent of any calendar date.
public struct TimeOfDay: Codable, Sendable, Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hour: try container.decodeIfPresent(Int.self, forKey: .hour) ?? 0,
            minute: try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        )
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

/// Day of week using the same numbering as `Calendar` (Sunday == 1).
public enum Weekday: Int, Codable, Sendable, CaseIterable, Hashable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Set<Weekday> = [.saturday, .sunday]

    public var previous: Weekday {
        Weekday(rawValue: rawValue == 1 ? 7 : rawValue - 1) ?? .sunday
    }
}

/// What a rule does while it is active.
public enum ScheduleAction: Codable, Sendable, Equatable, Hashable {
    case applyProfile(UUID)
    case muteApps(Set<AppKey>)
    case focusOn(Set<AppKey>)
}

/// "Mute Slack and Mail on weekdays between 09:00 and 12:30."
public struct ScheduleRule: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Days the window *starts* on. A window that wraps past midnight belongs to its
    /// start day, so "Friday 23:00–02:00" runs into Saturday morning.
    public var weekdays: Set<Weekday>
    public var start: TimeOfDay
    public var end: TimeOfDay
    public var action: ScheduleAction

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        weekdays: Set<Weekday> = Set(Weekday.allCases),
        start: TimeOfDay,
        end: TimeOfDay,
        action: ScheduleAction
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.weekdays = weekdays
        self.start = start
        self.end = end
        self.action = action
    }

    /// A window whose end is not after its start crosses midnight.
    public var wrapsMidnight: Bool {
        end <= start
    }

    /// Zero-length windows never fire; treating them as "all day" would be a nasty
    /// surprise for a user who mistyped.
    public var isEffectivelyEmpty: Bool {
        start == end || weekdays.isEmpty || !isEnabled
    }
}

/// Decides which rules are active and when the next boundary is.
///
/// The engine is pure: it takes a date and a calendar and returns an answer. That is
/// what lets the app run a *single* sleep until the next boundary instead of polling,
/// and what lets the tests cover midnight wrap and daylight-saving transitions without
/// waiting for real time to pass.
public enum ScheduleEngine {

    public static func isActive(_ rule: ScheduleRule, at date: Date, calendar: Calendar) -> Bool {
        guard !rule.isEffectivelyEmpty else { return false }
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard
            let weekdayValue = components.weekday,
            let today = Weekday(rawValue: weekdayValue),
            let hour = components.hour,
            let minute = components.minute
        else { return false }

        let nowMinutes = hour * 60 + minute
        let startMinutes = rule.start.minutesSinceMidnight
        let endMinutes = rule.end.minutesSinceMidnight

        if rule.wrapsMidnight {
            if rule.weekdays.contains(today), nowMinutes >= startMinutes { return true }
            return rule.weekdays.contains(today.previous) && nowMinutes < endMinutes
        }
        return rule.weekdays.contains(today) && nowMinutes >= startMinutes && nowMinutes < endMinutes
    }

    public static func activeRules(_ rules: [ScheduleRule], at date: Date, calendar: Calendar) -> [ScheduleRule] {
        rules.filter { isActive($0, at: date, calendar: calendar) }
    }

    /// The next moment any rule starts or stops, or `nil` when no rule can ever fire.
    ///
    /// Callers sleep exactly until this instant; there is no ticking timer anywhere in
    /// the app. `Calendar` does the date arithmetic so a window that falls inside a
    /// daylight-saving jump still resolves to a real instant.
    public static func nextTransition(
        for rules: [ScheduleRule],
        after date: Date,
        calendar: Calendar,
        searchDays: Int = 9
    ) -> Date? {
        var earliest: Date?

        for rule in rules where !rule.isEffectivelyEmpty {
            for dayOffset in -1..<searchDays {
                guard
                    let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: date))
                else { continue }
                let weekdayValue = calendar.component(.weekday, from: day)
                guard
                    let weekday = Weekday(rawValue: weekdayValue),
                    rule.weekdays.contains(weekday)
                else { continue }

                let startDate = self.date(for: rule.start, on: day, calendar: calendar)
                let endDay = rule.wrapsMidnight ? calendar.date(byAdding: .day, value: 1, to: day) : day
                let endDate = endDay.flatMap { self.date(for: rule.end, on: $0, calendar: calendar) }

                for candidate in [startDate, endDate].compactMap({ $0 }) where candidate > date {
                    if earliest == nil || candidate < earliest! {
                        earliest = candidate
                    }
                }
            }
        }

        return earliest
    }

    /// Resolves a wall-clock time on a given day. During a spring-forward gap the time
    /// may not exist; `nextTime` then yields the first valid instant after the gap,
    /// which is the behaviour a user expects from "mute at 02:30".
    private static func date(for time: TimeOfDay, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}
