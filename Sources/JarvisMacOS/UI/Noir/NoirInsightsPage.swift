import SwiftUI

// MARK: - Insights

struct NoirInsightsPage: View {
    @ObservedObject var appState: AppState

    @State private var range: StatsRange = .week
    @State private var summary = StatsSummary()
    @State private var buckets: [DayBucket] = []

    var body: some View {
        NoirPage(
            eyebrow: "Small moments, added up",
            title: "Your time, given back.",
            sub: "A little perspective on how Jarvis fits into your day.",
            trailing: AnyView(
                HStack(spacing: 10) {
                    NoirSegmented(
                        options: ["Day", "Week", "Year", "Lifetime"],
                        selection: Binding(
                            get: { range.rawValue },
                            set: { range = StatsRange(rawValue: $0) ?? .week }
                        )
                    )
                    NoirIconButton(icon: "arrow.clockwise", help: "Refresh usage") {
                        Task { await refresh() }
                    }
                }
            )
        ) {
            statGrid

            NoirSectionHeading(
                title: "Daily activity",
                trailing: AnyView(
                    Text("Last 7 days")
                        .font(.system(size: 10))
                        .foregroundStyle(NoirPalette.muted)
                )
            )

            NoirCard(padded: true) {
                HStack {
                    Text("Time spent speaking")
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.muted)
                    Spacer(minLength: 8)
                    NoirTag(text: "On-device data")
                }
                .padding(.bottom, 6)

                chart
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    NoirSectionHeading(title: "In a few words")
                    NoirCard {
                        VStack(spacing: 0) {
                            statRow("Words spoken", value: formatted(summary.chars / 5))
                            NoirDivider()
                            statRow("Copies", value: formatted(summary.copies))
                            NoirDivider()
                            statRow("Failed commands", value: formatted(summary.commandsFailed))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    NoirSectionHeading(title: "Behind the scenes")
                    NoirCard {
                        VStack(spacing: 0) {
                            statRow("Prompt tokens", value: formatted(summary.tokensPrompt))
                            NoirDivider()
                            statRow("Completion tokens", value: formatted(summary.tokensCompletion))
                            NoirDivider()
                            statRow(
                                "Time saved",
                                sub: "Compared with typing at 40 wpm.",
                                value: duration(summary.timeSavedSecs),
                                valueColor: NoirPalette.green
                            )
                        }
                    }
                }
            }

            Text("Usage comes from your configured event storage. Nothing leaves this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 18)
        }
        .task { await refresh() }
        .onChange(of: range) { _, _ in
            Task { await refresh() }
        }
    }

    // MARK: Stats

    private var statGrid: some View {
        HStack(spacing: 12) {
            statCard(
                label: "Time talking",
                value: duration(summary.talkSecs),
                sub: "spoken naturally"
            )
            statCard(
                label: "Sessions",
                value: formatted(summary.sessions),
                sub: "conversations started"
            )
            statCard(
                label: "Commands",
                value: formatted(summary.commandsRun),
                sub: "actions requested"
            )
            statCard(
                label: "Success rate",
                value: successText,
                sub: "completed successfully"
            )
        }
    }

    private func statCard(label: String, value: String, sub: String) -> some View {
        NoirCard(padded: true) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1)
                .foregroundStyle(NoirPalette.muted)
            Text(value)
                .font(.system(size: 29, weight: .regular))
                .tracking(-0.9)
                .foregroundStyle(NoirPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 13)
            Text(sub)
                .font(.system(size: 10))
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 5)
        }
    }

    private var successText: String {
        let total = summary.commandsRun + summary.commandsFailed
        guard total > 0 else { return "—" }
        return "\(Int(summary.successPct.rounded()))%"
    }

    // MARK: Chart

    private var chart: some View {
        let days = Array(buckets.suffix(7))
        let maxTalk = max(1, days.map(\.talkSecs).max() ?? 1)
        return Group {
            if days.isEmpty {
                Text("No usage yet — press ⌘⇧D and talk.")
                    .font(.system(size: 12))
                    .foregroundStyle(NoirPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                HStack(alignment: .bottom, spacing: 16) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, bucket in
                        VStack(spacing: 10) {
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: index == days.count - 1
                                                ? [Color(hex: 0x8B85AE), Color(hex: 0xC4BFE3)]
                                                : [Color(hex: 0x56516E), Color(hex: 0x9C96C1)],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(maxWidth: 32)
                                    .frame(width: 32,
                                           height: max(3, bucket.talkSecs / maxTalk * 135))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(Color(hex: 0xC9BFFF).opacity(0.10), lineWidth: 1)
                                    )
                            }
                            .frame(height: 135, alignment: .bottom)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(NoirPalette.line).frame(height: 1)
                            }

                            Text(shortDay(bucket.day))
                                .font(.system(size: 10))
                                .foregroundStyle(NoirPalette.muted)
                        }
                    }
                }
                .frame(height: 180)
                .padding(.top, 4)
            }
        }
    }

    private func shortDay(_ iso: String) -> String {
        String(iso.suffix(5).replacingOccurrences(of: "-", with: "/"))
    }

    // MARK: Rows

    private func statRow(
        _ title: String,
        sub: String? = nil,
        value: String,
        valueColor: Color = NoirPalette.secondary
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(NoirPalette.text)
                if let sub {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.muted)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 19)
        .frame(minHeight: 54)
    }

    // MARK: Data

    private func refresh() async {
        let provider = StatsProvider(dbManager: appState.dbManager)
        let selected = await provider.buckets(for: range)
        summary = StatsSummary.sum(selected)
        buckets = await provider.buckets(for: .week)
    }

    private func formatted(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func duration(_ secs: Double) -> String {
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        let hours = Int(secs / 3600)
        let minutes = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}
