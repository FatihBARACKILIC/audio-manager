import Foundation
import Testing

@testable import AudioDomain

@Suite("Schedule engine")
struct ScheduleTests {

    /// Fixed calendar and time zone: schedules must be reproducible, never dependent on
    /// the machine running the tests.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ string: String, timeZone: String = "Europe/Istanbul") -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: timeZone)!
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)!
    }

    private func rule(
        weekdays: Set<Weekday> = Set(Weekday.allCases),
        start: (Int, Int),
        end: (Int, Int),
        enabled: Bool = true
    ) -> ScheduleRule {
        ScheduleRule(
            name: "Test",
            isEnabled: enabled,
            weekdays: weekdays,
            start: TimeOfDay(hour: start.0, minute: start.1),
            end: TimeOfDay(hour: end.0, minute: end.1),
            action: .muteApps([.bundle("com.tinyspeck.slackmacgap")])
        )
    }

    @Test("A window is active inside its bounds and inactive outside")
    func simpleWindow() {
        let rule = rule(start: (9, 0), end: (12, 30))

        // 2026-09-15 is a Tuesday.
        #expect(!ScheduleEngine.isActive(rule, at: date("2026-09-15 08:59"), calendar: calendar))
        #expect(ScheduleEngine.isActive(rule, at: date("2026-09-15 09:00"), calendar: calendar))
        #expect(ScheduleEngine.isActive(rule, at: date("2026-09-15 12:29"), calendar: calendar))
        #expect(!ScheduleEngine.isActive(rule, at: date("2026-09-15 12:30"), calendar: calendar))
    }

    @Test("A window only fires on the weekdays it names")
    func weekdayFiltering() {
        let weekdaysOnly = rule(weekdays: Weekday.weekdays, start: (9, 0), end: (17, 0))

        #expect(ScheduleEngine.isActive(weekdaysOnly, at: date("2026-09-18 10:00"), calendar: calendar)) // Friday
        #expect(!ScheduleEngine.isActive(weekdaysOnly, at: date("2026-09-19 10:00"), calendar: calendar)) // Saturday
    }

    @Test("A window crossing midnight stays active into the next morning")
    func midnightWrap() {
        // Friday 23:00 to 02:00.
        let rule = rule(weekdays: [.friday], start: (23, 0), end: (2, 0))

        #expect(ScheduleEngine.isActive(rule, at: date("2026-09-18 23:30"), calendar: calendar)) // Friday night
        #expect(ScheduleEngine.isActive(rule, at: date("2026-09-19 01:59"), calendar: calendar)) // Saturday morning
        #expect(!ScheduleEngine.isActive(rule, at: date("2026-09-19 02:00"), calendar: calendar))
        #expect(!ScheduleEngine.isActive(rule, at: date("2026-09-19 23:30"), calendar: calendar)) // Saturday night
    }

    @Test("A disabled or zero-length rule never fires")
    func emptyRules() {
        let disabled = rule(start: (9, 0), end: (17, 0), enabled: false)
        let zeroLength = rule(start: (9, 0), end: (9, 0))
        let noDays = rule(weekdays: [], start: (9, 0), end: (17, 0))

        #expect(!ScheduleEngine.isActive(disabled, at: date("2026-09-15 10:00"), calendar: calendar))
        #expect(!ScheduleEngine.isActive(zeroLength, at: date("2026-09-15 09:00"), calendar: calendar))
        #expect(!ScheduleEngine.isActive(noDays, at: date("2026-09-15 10:00"), calendar: calendar))
    }

    @Test("The next transition is the upcoming start")
    func nextTransitionIsStart() {
        let rule = rule(start: (9, 0), end: (12, 30))
        let next = ScheduleEngine.nextTransition(
            for: [rule],
            after: date("2026-09-15 07:00"),
            calendar: calendar
        )

        #expect(next == date("2026-09-15 09:00"))
    }

    @Test("Inside a window the next transition is its end")
    func nextTransitionIsEnd() {
        let rule = rule(start: (9, 0), end: (12, 30))
        let next = ScheduleEngine.nextTransition(
            for: [rule],
            after: date("2026-09-15 10:00"),
            calendar: calendar
        )

        #expect(next == date("2026-09-15 12:30"))
    }

    @Test("The earliest boundary across several rules wins")
    func earliestAcrossRules() {
        let morning = rule(start: (9, 0), end: (12, 0))
        let lunch = rule(start: (11, 0), end: (13, 0))

        let next = ScheduleEngine.nextTransition(
            for: [morning, lunch],
            after: date("2026-09-15 10:00"),
            calendar: calendar
        )

        #expect(next == date("2026-09-15 11:00"))
    }

    @Test("A weekly rule jumps to next week when today is past")
    func jumpsToNextWeek() {
        let mondayOnly = rule(weekdays: [.monday], start: (9, 0), end: (10, 0))
        let next = ScheduleEngine.nextTransition(
            for: [mondayOnly],
            after: date("2026-09-15 12:00"), // Tuesday
            calendar: calendar
        )

        #expect(next == date("2026-09-21 09:00")) // the following Monday
    }

    @Test("No enabled rule means no transition to wait for")
    func noTransitionWhenNothingScheduled() {
        #expect(ScheduleEngine.nextTransition(for: [], after: Date(), calendar: calendar) == nil)

        let disabled = rule(start: (9, 0), end: (10, 0), enabled: false)
        #expect(ScheduleEngine.nextTransition(for: [disabled], after: Date(), calendar: calendar) == nil)
    }

    @Test("A rule scheduled inside the spring-forward gap still resolves to a real instant")
    func daylightSavingGap() {
        // Most of Europe moves 02:00 to 03:00 on 2026-03-29; 02:30 does not exist.
        var europeanCalendar = Calendar(identifier: .gregorian)
        europeanCalendar.timeZone = TimeZone(identifier: "Europe/Berlin")!

        let rule = rule(weekdays: [.sunday], start: (2, 30), end: (4, 0))
        let next = ScheduleEngine.nextTransition(
            for: [rule],
            after: date("2026-03-29 00:30", timeZone: "Europe/Berlin"),
            calendar: europeanCalendar
        )

        #expect(next != nil)
        // The skipped time resolves forward to the first instant that exists.
        #expect(next == date("2026-03-29 03:00", timeZone: "Europe/Berlin"))
    }

    @Test("Active rules are reported together")
    func activeRuleList() {
        let morning = rule(start: (9, 0), end: (12, 0))
        let allDay = rule(start: (0, 1), end: (23, 59))
        let evening = rule(start: (18, 0), end: (20, 0))

        let active = ScheduleEngine.activeRules(
            [morning, allDay, evening],
            at: date("2026-09-15 10:00"),
            calendar: calendar
        )

        #expect(active.count == 2)
    }
}
