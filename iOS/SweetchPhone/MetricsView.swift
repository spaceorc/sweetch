import Charts
import SwiftUI

/// How well sweetch does, in numbers without any text — counted on the Mac from the dictations and
/// the keyboard's log: the last week at a glance, and the last two weeks day by day.
struct MetricsView: View {
    @State private var metrics: Metrics?
    @State private var problem: String?

    struct Metrics {
        struct Day: Identifiable {
            let date: Date
            let typed: Int
            let dictated: Int
            let latency: Double?
            let autocorrected: Int
            /// Per 100 words typed; nil on a day with nothing typed.
            let good: Double?
            let undone: Double?
            let fixes: Double?
            var id: Date { date }
        }

        let week: [String: Any]
        let days: [Day]
        /// What the models cost (the Mac's Metrics.llm).
        let llm: [String: Any]

        init(_ json: [String: Any]) {
            week = json["week"] as? [String: Any] ?? [:]
            llm = json["llm"] as? [String: Any] ?? [:]
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            days = (json["days"] as? [[String: Any]] ?? []).compactMap { d in
                guard let date = (d["day"] as? String).flatMap(f.date(from:)) else { return nil }
                return Day(date: date, typed: d["typed_words"] as? Int ?? 0, dictated: d["dictated_words"] as? Int ?? 0,
                           latency: d["latency_median"] as? Double, autocorrected: d["autocorrected"] as? Int ?? 0,
                           good: d["good_autocorrect_per_100"] as? Double, undone: d["undone_per_100"] as? Double,
                           fixes: d["fixes_per_100"] as? Double)
            }
        }

        func number(_ key: String) -> Double? { (week[key] as? NSNumber)?.doubleValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let metrics {
                    qualityChart(metrics)
                    section("Typing, this week") {
                        tile("Fixed by hand", per100(metrics.number("fixes_per_100")), "per 100 words · \(minutes(metrics.number("fixing_minutes"))) spent, \(seconds(metrics.number("fix_seconds_median"))) a fix")
                        tile("Autocorrected", per100(metrics.number("good_autocorrect_per_100")), "per 100 words, kept · saved about \(minutes(metrics.number("autocorrect_saved_minutes")))")
                        tile("Taken back", per100(metrics.number("undone_per_100")), "autocorrections per 100 words · \(percent(metrics.number("autocorrect_undone_rate"))) of them")
                        tile("Typos left", String(format: "%.1f", metrics.number("typos_left_per_100") ?? 0), "per 100 words: the decoder doubted, nothing changed")
                    }
                    section("Dictation") {
                        tile("To text", seconds(metrics.number("latency_median")), "median after release · 90% within \(seconds(metrics.number("latency_p90")))")
                        tile("Words", count(metrics.number("dictated_words")), "\(count(metrics.number("dictations"))) dictations · \(count(metrics.number("phone_dictations"))) from the iPhone")
                        tile("Changed after", percent(metrics.number("dictation_edit_rate")),
                             metrics.number("dictation_words_checked").map { $0 > 0 ? "of \(count($0)) dictated words seen to the end" : "no dictation seen to the end yet" } ?? "")
                        tile("Speaking", "\(count(metrics.number("speaking_wpm"))) wpm", "typing \(count(metrics.number("typing_wpm"))) wpm on the phone")
                    }
                    wordsChart(metrics)
                    latencyChart(metrics)
                    section("Overall, this week") {
                        tile("Dictated", percent(metrics.number("dictated_share")), "of \(count((metrics.number("dictated_words") ?? 0) + (metrics.number("typed_words") ?? 0))) words · \(count(metrics.number("typed_words"))) typed here")
                        tile("Speaking over typing", duration(metrics.number("saved_minutes")), "estimate: typing at your phone speed")
                        tile("Backspaces", count(metrics.number("deletes_per_100")), "per 100 words typed")
                        tile("Suggestions", percent(metrics.number("suggestion_share")), "of the words typed")
                    }
                    section("Models") {
                        tile("Today", dollars(metrics.llm["today"]), "settling, prefixes, corrections")
                        tile("This week", dollars(metrics.llm["week"]), "\(count((metrics.llm["week_calls"] as? NSNumber)?.doubleValue)) calls · \(dollars(metrics.llm["all"])) all kept")
                        ForEach(Array((metrics.llm["by_purpose"] as? [[String: Any]] ?? []).prefix(4).enumerated()), id: \.offset) { _, row in
                            tile(row["name"] as? String ?? "?", dollars(row["cost"]), "this week · \(count((row["calls"] as? NSNumber)?.doubleValue)) calls")
                        }
                    }
                    Text("Counted on the Mac from what it keeps — the dictations and the keyboard's log — as numbers only; no text leaves it.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let problem {
                    ContentUnavailableView("No Mac in reach", systemImage: "chart.bar.xaxis", description: Text(problem))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("How it goes")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            guard let mac = await Server.reachable() else { throw Failure("No Mac answers.") }
            metrics = Metrics(try await mac.metrics())
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Dollars, to the cent — or to a tenth of one below a dollar: these are small sums.
    private func dollars(_ value: Any?) -> String {
        let v = (value as? NSNumber)?.doubleValue ?? 0
        return v >= 1 ? String(format: "$%.2f", v) : String(format: "$%.3f", v)
    }

    // MARK: - Parts

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) { content() }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The keyboard day by day: per 100 words typed, autocorrections kept, autocorrections taken
    /// back, and fixes by hand — whether autocorrection helps, and how much is left to the user.
    private func qualityChart(_ m: Metrics) -> some View {
        let typed = m.days.filter { $0.typed > 0 }
        return card("Typing: per 100 words, day by day") {
            Chart {
                ForEach(typed) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Per 100", day.good ?? 0))
                        .foregroundStyle(by: .value("What", "Autocorrected"))
                        .position(by: .value("What", "Autocorrected"))
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Per 100", day.undone ?? 0))
                        .foregroundStyle(by: .value("What", "Taken back"))
                        .position(by: .value("What", "Taken back"))
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Per 100", day.fixes ?? 0))
                        .foregroundStyle(by: .value("What", "Fixed by hand"))
                        .position(by: .value("What", "Fixed by hand"))
                }
            }
            .chartForegroundStyleScale(["Autocorrected": Color.green, "Taken back": Color.red, "Fixed by hand": Color.orange])
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.day()) } }
            .frame(height: 180)
            if typed.isEmpty { Text("Nothing typed on the keyboard yet").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func wordsChart(_ m: Metrics) -> some View {
        card("Words a day") {
            Chart(m.days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.dictated))
                    .foregroundStyle(by: .value("How", "Dictated"))
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.typed))
                    .foregroundStyle(by: .value("How", "Typed"))
            }
            .chartForegroundStyleScale(["Dictated": Color.indigo, "Typed": Color.orange])
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day()) } }
            .frame(height: 170)
        }
    }

    private func latencyChart(_ m: Metrics) -> some View {
        card("Release to text, median") {
            Chart(m.days.filter { $0.latency != nil }) { day in
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Seconds", day.latency ?? 0))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Day", day.date, unit: .day), y: .value("Seconds", day.latency ?? 0))
            }
            .foregroundStyle(Color.indigo)
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text("\(value.as(Double.self) ?? 0, specifier: "%.1f") s") } } }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day()) } }
            .frame(height: 140)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Formatting

    private func count(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 10_000 ? String(format: "%.1fk", value / 1000) : String(Int(value.rounded()))
    }

    private func per100(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }

    private func minutes(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 1 ? "\(Int((value * 60).rounded())) s" : "\(Int(value.rounded())) min"
    }

    private func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f s", $0) } ?? "—" }

    private func duration(_ minutes: Double?) -> String {
        guard let minutes else { return "—" }
        return minutes >= 60 ? String(format: "%.0f h %02.0f min", (minutes / 60).rounded(.down), minutes.truncatingRemainder(dividingBy: 60))
            : "\(Int(minutes)) min"
    }
}
