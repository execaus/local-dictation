import Foundation

public struct ScheduleRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var weekdays: Set<Int> // Gregorian Calendar: Sunday = 1 ... Saturday = 7
    public var startMinute: Int
    public var endMinute: Int
    public var isEnabled: Bool

    public init(id: UUID = UUID(), weekdays: Set<Int>, startMinute: Int,
                endMinute: Int, isEnabled: Bool = true) {
        self.id = id
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.isEnabled = isEnabled
    }

    public var isValid: Bool {
        isEnabled && !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) }
            && (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute)
            && startMinute != endMinute
    }
}

public struct ActiveInterval: Equatable, Sendable {
    public let ruleID: UUID
    public let start: Date
    public let end: Date

    public var key: String { "\(ruleID.uuidString):\(Int(start.timeIntervalSince1970))" }
}

public enum ScheduleEvaluator {
    public static func activeIntervals(at now: Date, rules: [ScheduleRule],
                                       calendar: Calendar = .current) -> [ActiveInterval] {
        let today = calendar.startOfDay(for: now)
        return rules.filter(\.isValid).flatMap { rule in
            [0, -1].compactMap { dayOffset -> ActiveInterval? in
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                      rule.weekdays.contains(calendar.component(.weekday, from: day)),
                      let start = calendar.date(bySettingHour: rule.startMinute / 60,
                                                minute: rule.startMinute % 60, second: 0, of: day),
                      let endDay = calendar.date(byAdding: .day,
                                                 value: rule.endMinute <= rule.startMinute ? 1 : 0,
                                                 to: day),
                      let end = calendar.date(bySettingHour: rule.endMinute / 60,
                                              minute: rule.endMinute % 60, second: 0, of: endDay),
                      start <= now, now < end else { return nil }
                return ActiveInterval(ruleID: rule.id, start: start, end: end)
            }
        }
    }
}

public struct HoldState: Equatable, Sendable {
    public var manual = false
    public var timerEnd: Date?
    public var suppressedIntervals: Set<String> = []

    public init() {}

    public mutating func stop(at now: Date, rules: [ScheduleRule], calendar: Calendar = .current) {
        manual = false
        timerEnd = nil
        suppressedIntervals.formUnion(ScheduleEvaluator.activeIntervals(at: now, rules: rules,
                                                                         calendar: calendar).map(\.key))
    }

    public mutating func evaluate(at now: Date, rules: [ScheduleRule],
                                  calendar: Calendar = .current) -> HoldReason {
        if let timerEnd, timerEnd <= now { self.timerEnd = nil }
        let active = ScheduleEvaluator.activeIntervals(at: now, rules: rules, calendar: calendar)
        suppressedIntervals.formIntersection(Set(active.map(\.key)))
        if manual { return .manual }
        if let timerEnd { return .timer(timerEnd) }
        if let first = active.first(where: { !suppressedIntervals.contains($0.key) }) {
            return .schedule(first.end)
        }
        return .inactive
    }
}

public enum HoldReason: Equatable, Sendable {
    case inactive, manual, timer(Date), schedule(Date)
}
