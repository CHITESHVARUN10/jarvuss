import SwiftUI

/// Insights pane — range segment, stat tiles, daily chart, breakdown.
struct InsightsPane: View {
    @ObservedObject var appState: AppState
    @State private var range: StatsRange = .week
    @State private var summary = StatsSummary()
    @State private var buckets: [DayBucket] = []

    private var refreshButton: some View {
        JRefreshButton(help: "Refresh usage stats") {
            Task { await refresh() }
        }
    }

    var body: some View {
        paneBody
            .padding(.horizontal, 22)
            .task { await refresh() }
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                JSegment(
                    options: StatsRange.allCases.map { ($0, $0.rawValue) },
                    selection: $range
                ) { _ in Task { await refresh() } }
                // Fixed width: keep the same pinned width the old sidebar used
                // so the panel never jitters when the selected label bolds.
                .frame(width: 260)

                Spacer(minLength: 0)

                refreshButton
            }
            .padding(.bottom, 16)

            tiles

            JLabel(text: "Daily activity")
                .padding(.top, 22)

            JCard {
                dailyChart
            }
            .padding(.top, 9)

            JLabel(text: "Breakdown")
                .padding(.top, 22)

            JCard {
                JRow(title: "Words spoken", first: true) {
                    kv("\(summary.chars / 5)")
                }
                JRow(title: "Prompt tokens") {
                    kv("\(summary.tokensPrompt)")
                }
                JRow(title: "Completion tokens") {
                    kv("\(summary.tokensCompletion)")
                }
                JRow(title: "Failed commands") {
                    kv("\(summary.commandsFailed)")
                }
                JRow(title: "Time saved", sub: "vs typing, at 40 wpm") {
                    Text(formatDuration(summary.timeSavedSecs))
                        .font(JType.kv)
                        .foregroundStyle(JColor.ok)
                }
            }
            .padding(.top, 9)
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                wideTile(value: formatDuration(summary.talkSecs), sub: "spoken", label: "Time talking")
            }
            HStack(spacing: 8) {
                tile(value: "\(summary.sessions)", label: "Sessions")
                tile(value: "\(summary.copies)", label: "Copies")
            }
            HStack(spacing: 8) {
                tile(value: "\(summary.commandsRun)", label: "Commands")
                tile(value: String(format: "%.0f%%", summary.successPct), label: "Success")
            }
        }
    }

    private func tile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(JColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(JColor.ink4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: JRadius.md, style: .continuous)
                .fill(JColor.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: JRadius.md, style: .continuous)
                .strokeBorder(JColor.line, lineWidth: 1)
        )
    }

    private func wideTile(value: String, sub: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(JColor.ink)
                Text(sub)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(JColor.ink4)
            }
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(JColor.ink4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: JRadius.md, style: .continuous)
                .fill(JColor.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: JRadius.md, style: .continuous)
                .strokeBorder(JColor.line, lineWidth: 1)
        )
    }

    // MARK: - Daily chart

    private var dailyChart: some View {
        let days = Array(buckets.suffix(7))
        let maxTalk = max(1, days.map(\.talkSecs).max() ?? 1)
        return VStack(spacing: 7) {
            if days.isEmpty {
                Text("No usage yet — press ⌘⇧D and talk.")
                    .font(.system(size: 12))
                    .foregroundStyle(JColor.ink4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(days, id: \.day) { bucket in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [JColor.accent, JColor.accent.opacity(0.35)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(3, CGFloat(bucket.talkSecs / maxTalk) * 82))
                            .frame(maxWidth: .infinity)
                            .help("\(bucket.day): \(bucket.sessions) sessions · \(formatShortDuration(bucket.talkSecs))")
                    }
                }
                .frame(height: 82)

                HStack(spacing: 5) {
                    ForEach(days, id: \.day) { bucket in
                        Text(shortDay(bucket.day))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(JColor.ink4)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func kv(_ text: String) -> some View {
        Text(text)
            .font(JType.kv)
            .foregroundStyle(JColor.ink2)
    }

    private func refresh() async {
        let provider = StatsProvider(dbManager: appState.dbManager)
        let list = await provider.buckets(for: range)
        buckets = list
        summary = StatsSummary.sum(list)
    }

    private func shortDay(_ iso: String) -> String {
        String(iso.suffix(5).replacingOccurrences(of: "-", with: "/"))
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
