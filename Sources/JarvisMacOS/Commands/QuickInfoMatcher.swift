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
        switch coreMatchQuickInfo(lower: lower) {
        case .currentTime: return .time
        case .currentDate: return .date
        case .currentDay: return .day
        case .currentMonth: return .month
        case .currentYear: return .year
        default: return nil
        }
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

}
