import Foundation

enum CalendarWeekStart: Int, Codable, CaseIterable, Identifiable {
    case sunday = 1, monday = 2
    var id: Int { rawValue }
    var title: String { self == .monday ? "月曜日" : "日曜日" }
}

/// Screen navigation is session-only; calendar preferences belong to BudgetSnapshot.
struct CalendarNavigation: Equatable {
    private(set) var month: Date
    private(set) var selectedDay: Date
    init(now: Date = Date(), calendar: Calendar = .current) {
        let day = EntryDateLimits.clamp(now, calendar: calendar)
        month = BudgetCalendar.startOfMonth(day, calendar: calendar)
        selectedDay = calendar.startOfDay(for: day)
    }
    mutating func showMonth(_ date: Date, calendar: Calendar = .current) {
        let next = BudgetCalendar.startOfMonth(EntryDateLimits.clamp(date, calendar: calendar), calendar: calendar)
        guard next != month else { return }
        let day = calendar.component(.day, from: selectedDay)
        month = next
        let last = calendar.range(of: .day, in: .month, for: next)?.count ?? 1
        selectedDay = calendar.date(byAdding: .day, value: min(day, last) - 1, to: next) ?? next
    }
    mutating func moveMonth(_ amount: Int, calendar: Calendar = .current) {
        guard let next = calendar.date(byAdding: .month, value: amount, to: month) else { return }
        showMonth(next, calendar: calendar)
    }
    mutating func changeYear(_ year: Int, calendar: Calendar = .current) {
        guard (1900...2099).contains(year) else { return }
        let monthNumber = calendar.component(.month, from: month)
        guard let date = calendar.date(from: DateComponents(year: year, month: monthNumber, day: 1)) else { return }
        showMonth(date, calendar: calendar)
    }
    mutating func selectMonth(_ number: Int, calendar: Calendar = .current) {
        guard (1...12).contains(number) else { return }
        let year = calendar.component(.year, from: month)
        guard let date = calendar.date(from: DateComponents(year: year, month: number, day: 1)) else { return }
        showMonth(date, calendar: calendar)
    }
    mutating func selectDay(_ date: Date, calendar: Calendar = .current) {
        selectedDay = calendar.startOfDay(for: EntryDateLimits.clamp(date, calendar: calendar))
        month = BudgetCalendar.startOfMonth(selectedDay, calendar: calendar)
    }
}

struct CalendarDaySummary: Equatable {
    var totals = MoneyTotals()
    var hasIncome = false
    var hasExpense = false
    var hasTransfer = false
    var count = 0
}

enum BudgetCalendar {
    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
    static func weekdays(start: CalendarWeekStart) -> [String] {
        let days = ["日", "月", "火", "水", "木", "金", "土"]
        let offset = start.rawValue - 1
        return Array(days[offset...] + days[..<offset])
    }
    static func cells(month: Date, start: CalendarWeekStart, calendar: Calendar = .current) -> [Date?] {
        let first = startOfMonth(month, calendar: calendar)
        guard let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let offset = (calendar.component(.weekday, from: first) - start.rawValue + 7) % 7
        var result = Array<Date?>(repeating: nil, count: offset)
        result += range.map { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }
    /// Call with effective entries so refunds follow their original expense's totals flag.
    static func summaries(_ entries: [BudgetEntry], calendar: Calendar = .current) -> [Date: CalendarDaySummary] {
        let groups: [Date: [BudgetEntry]] = Dictionary(grouping: entries, by: { calendar.startOfDay(for: $0.date) })
        var result: [Date: CalendarDaySummary] = [:]
        for (day, values) in groups {
            var summary = CalendarDaySummary()
            summary.totals = BudgetSummary.totals(values)
            summary.count = values.count
            for entry in values {
                if entry.kind == .transfer { summary.hasTransfer = true }
                if entry.includedInTotals {
                    if entry.kind == .income { summary.hasIncome = true }
                    if entry.kind == .expense || entry.kind == .refund { summary.hasExpense = true }
                }
            }
            result[day] = summary
        }
        return result
    }
}


enum EntryDateLimits {
    static func range(calendar: Calendar = .current) -> ClosedRange<Date> {
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        let first = civil.date(from: DateComponents(year: 1900, month: 1, day: 1))!
        let last = civil.date(from: DateComponents(year: 2099, month: 12, day: 31))!
        return first...last
    }
    static func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard date.timeIntervalSince1970.isFinite else { return false }
        return range(calendar: calendar).contains(calendar.startOfDay(for: date))
    }
    static func clamp(_ date: Date, calendar: Calendar = .current) -> Date {
        let limits = range(calendar: calendar)
        return min(max(date, limits.lowerBound), limits.upperBound)
    }
}

extension BudgetCalendar {
    static func isFutureMonth(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        startOfMonth(date, calendar: calendar) > startOfMonth(now, calendar: calendar)
    }
}
