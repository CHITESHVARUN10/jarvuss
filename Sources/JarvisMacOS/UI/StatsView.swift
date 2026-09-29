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
    let dbManager: DBManager

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
    let dbManager: DBManager
    @State private var range: StatsRange = .week
    @State private var summary = StatsSummary()
    @State private var buckets: [DayBucket] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("USAGE STATS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Picker("", selection: $range) {
                    ForEach(StatsRange.allCases, id: \.self) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)
                .clipped()
                .onChange(of: range) { _ in Task { await refresh() } }
            }
            LazyVGrid(columns: [GridItem(.flexible(minimum: 40), spacing: 8), GridItem(.flexible(minimum: 40), spacing: 8)], spacing: 8) {
                statCard("Talk time", value: formatDuration(summary.talkSecs), icon: "mic.fill")
                statCard("Sessions", value: "\(summary.sessions)", icon: "waveform")
                statCard("Words", value: "\(summary.chars / 5)", icon: "textformat")
                statCard("Tokens in", value: "\(summary.tokensPrompt)", icon: "arrow.down.circle")
                statCard("Tokens out", value: "\(summary.tokensCompletion)", icon: "arrow.up.circle")
                statCard("Copies", value: "\(summary.copies)", icon: "doc.on.doc")
                statCard("Commands", value: "\(summary.commandsRun)", icon: "bolt.fill")
                statCard("Success", value: String(format: "%.0f%%", summary.successPct), icon: "checkmark.circle")
                statCard("Time saved", value: formatDuration(summary.timeSavedSecs), icon: "clock.fill")
            }
            if !buckets.isEmpty {
                Text("BY DAY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color.white.opacity(0.4))
                ForEach(buckets.suffix(7), id: \.day) { b in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.day)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                        Text("\(b.sessions)sess · \(formatShortDuration(b.talkSecs)) · \(b.copies)⧉ · \(b.commandsRun)✓")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("No usage yet — press ⌘⇧D and talk.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
        .task { await refresh() }
    }

    private func refresh() async {
        let provider = StatsProvider(dbManager: dbManager)
        let list = await provider.buckets(for: range)
        buckets = list
        summary = StatsSummary.sum(list)
    }

    private func statCard(_ label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.35))
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
