import Foundation

/// What kind of instant local answer a quick-info query wants.
enum QuickInfoKind {
    case time
    case date
    case day
    case month
    case year
}

/// Single pattern table for instant local answers (time/date/day/month/year).
///
/// Three layers used to carry their own copies of these patterns and could
/// disagree (`FastPathRouter` sent "what time is it" to Ollama while AppState
/// answered it locally): AppState (presentation fast-path), FastPathRouter
/// (routing) and `ActionPlanner.parseInfoCommand` (systemInfo mapping) all
/// match through here now.
///
/// Input must already be lowercased, wake-word stripped and trimmed —
/// every caller normalizes the same way before matching.
enum QuickInfoMatcher {
    static func match(_ lower: String) -> QuickInfoKind? {
        // Priority is significant: "what day is today" appears in both the
        // date and day tables — date wins, matching historical behavior.
        if containsAny(lower, timePatterns) { return .time }
        if containsAny(lower, datePatterns) { return .date }
        if containsAny(lower, dayPatterns) { return .day }
        if containsAny(lower, monthPatterns) { return .month }
        if containsAny(lower, yearPatterns) { return .year }
        return nil
    }

    /// True when the input looks multi-clause — quick-info fast-paths must
    /// leave those to the conjunction splitter so no clause is swallowed
    /// ("what time is it and open chrome" answers time AND opens chrome).
    static func looksCompound(_ lower: String) -> Bool {
        lower.contains(" and ") || lower.contains(" then ")
    }

    /// The SystemInfoAction this kind routes to in the planner/executor path.
    static func systemInfoAction(for kind: QuickInfoKind) -> SystemInfoAction {
        switch kind {
        case .time:  return .currentTime
        case .date:  return .currentDate
        case .day:   return .currentDay
        case .month: return .currentMonth
        case .year:  return .currentYear
        }
    }

    private static func containsAny(_ lower: String, _ patterns: [String]) -> Bool {
        patterns.contains(where: { lower.contains($0) })
    }

    private static let timePatterns = [
        "what is the time", "what's the time", "what time is it",
        "tell me the time", "current time", "time right now",
        "what is time", "whats the time", "show me the time",
        "the time", "time please",
    ]

    private static let datePatterns = [
        "what is today's date", "what is the date", "today's date",
        "what day is today", "what is today", "what date is it",
        "tell me the date", "current date", "todays date",
        "what's today's date", "whats todays date", "show me the date",
        "date today", "date right now",
    ]

    private static let dayPatterns = [
        "what day is it", "what day is this", "which day is it",
        "which day is today", "tell me the day", "what day",
    ]

    private static let monthPatterns = [
        "what month is it", "what month", "which month",
        "tell me the month", "current month",
    ]

    private static let yearPatterns = [
        "what year is it", "what year", "current year", "which year",
    ]
}
