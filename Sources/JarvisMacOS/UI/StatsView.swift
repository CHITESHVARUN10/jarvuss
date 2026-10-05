import SwiftUI

enum StatsRange: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case year = "Year"
    case lifetime = "Lifetime"
}

struct StatsSummary {
    var talkSecs: Double = 0
    var sessions: Int = 0
    var chars: Int = 0
    var tokensPrompt: Int = 0
    var tokensCompletion: Int = 0
    var copies: Int = 0
    var commandsRun: Int = 0
    var commandsFailed: Int = 0
    var timeSavedSecs: Double = 0

    static func sum(_ buckets: [DayBucket]) -> StatsSummary {
        var s = StatsSummary()
        for b in buckets {
            s.talkSecs += b.talkSecs
            s.sessions += b.sessions
            s.chars += b.charsDictated
            s.tokensPrompt += b.tokensPromptEst
            s.tokensCompletion += b.tokensCompletionEst
            s.copies += b.copies
            s.commandsRun += b.commandsRun
            s.commandsFailed += b.commandsFailed
            s.timeSavedSecs += b.timeSavedSecs
        }
        return s
    }

    var successPct: Double {
        let total = commandsRun + commandsFailed
        guard total > 0 else { return 0 }
        return Double(commandsRun) / Double(total) * 100
    }
}

struct StatsProvider {
    let dbManager: EventLogging

    func buckets(for range: StatsRange) async -> [DayBucket] {
        let sinceDays: Int
        switch range {
        case .day: sinceDays = 0
        case .week: sinceDays = 6
        case .year: sinceDays = 364
        case .lifetime: sinceDays = 3650
        }
        let today = DayBucket.dayString()
        var merged: [String: DayBucket] = [:]
        if dbManager.isConfigured {
            for b in await dbManager.fetchDailyStats(sinceDays: sinceDays) {
                merged[b.day] = b
            }
        }
        for b in StatsRecorder.shared.bufferedDays() {
            if b.day < todayMinus(days: sinceDays, from: today) { continue }
            if var existing = merged[b.day] {
                existing.talkSecs += b.talkSecs
                existing.sessions += b.sessions
                existing.charsDictated += b.charsDictated
                existing.tokensPromptEst += b.tokensPromptEst
                existing.tokensCompletionEst += b.tokensCompletionEst
                existing.copies += b.copies
                existing.commandsRun += b.commandsRun
                existing.commandsFailed += b.commandsFailed
                existing.timeSavedSecs += b.timeSavedSecs
                merged[b.day] = existing
            } else {
                merged[b.day] = b
            }
        }
        let live = StatsRecorder.shared.snapshot()
        if live.day >= todayMinus(days: sinceDays, from: today) {
            if merged[live.day] == nil
                && (live.sessions > 0 || live.copies > 0 || live.commandsRun > 0 || live.tokensPromptEst > 0)
            {
                merged[live.day] = live
            }
        }
        return merged.values.sorted { $0.day < $1.day }
    }

    private func todayMinus(days: Int, from today: String) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .iso8601)
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: today) else { return today }
        let past = Calendar(identifier: .iso8601).date(byAdding: .day, value: -days, to: date) ?? date
        return fmt.string(from: past)
    }
}

struct StatsView: View {
    let dbManager: EventLogging
    @State private var range: StatsRange = .week
    @State private var summary = StatsSummary()
    @State private var buckets: [DayBucket] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Usage")
                    .font(JarvisType.title)
                    .foregroundStyle(JarvisColor.textPrimary)

                Spacer()

                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(JarvisColor.textSecondary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("Refresh usage stats")
            }

            Picker("", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Fixed width: the segmented control's intrinsic width shifts with
            // the selected segment (bold label), which resized the whole panel
            // when switching Day/Week/Year/Lifetime. 260 = sidebar 300 − 2×20.
            .frame(width: 260)
            .onChange(of: range) { _ in Task { await refresh() } }

            VStack(spacing: 0) {
                statRow("Talk time", value: formatDuration(summary.talkSecs))
                statRow("Sessions", value: "\(summary.sessions)")
                statRow("Words", value: "\(summary.chars / 5)")
                statRow("Tokens in", value: "\(summary.tokensPrompt)")
                statRow("Tokens out", value: "\(summary.tokensCompletion)")
                statRow("Copies", value: "\(summary.copies)")
                statRow("Commands", value: "\(summary.commandsRun)")
                statRow("Success", value: String(format: "%.0f%%", summary.successPct))
                statRow("Time saved", value: formatDuration(summary.timeSavedSecs), isLast: true)
            }

            if !buckets.isEmpty {
                Text("By day")
                    .font(JarvisType.caption)
                    .foregroundStyle(JarvisColor.textTertiary)
                ForEach(buckets.suffix(7), id: \.day) { b in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.day)
                            .font(JarvisType.dataSmall)
                            .foregroundStyle(JarvisColor.textSecondary)
                            .lineLimit(1)
                        Text("\(b.sessions)sess · \(formatShortDuration(b.talkSecs)) · \(b.copies)⧉ · \(b.commandsRun)✓")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(JarvisColor.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No usage yet — press ⌘⇧D and talk.")
                    .font(JarvisType.caption)
                    .foregroundStyle(JarvisColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let provider = StatsProvider(dbManager: dbManager)
        let list = await provider.buckets(for: range)
        buckets = list
        summary = StatsSummary.sum(list)
    }

    private func statRow(_ label: String, value: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(JarvisType.caption)
                    .foregroundStyle(JarvisColor.textSecondary)
                Spacer()
                Text(value)
                    .font(JarvisType.dataSmall)
                    .foregroundStyle(JarvisColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.vertical, 5)

            if !isLast {
                Rectangle()
                    .fill(JarvisColor.hairline)
                    .frame(height: 0.5)
            }
        }
    }

    private func formatDuration(_ secs: Double) -> String {
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return String(format: "%.1fm", secs / 60) }
        return String(format: "%.1fh", secs / 3600)
    }

    private func formatShortDuration(_ secs: Double) -> String {
        if secs < 60 { return "\(Int(secs))s" }
        return String(format: "%.0fm", secs / 60)
    }
}
