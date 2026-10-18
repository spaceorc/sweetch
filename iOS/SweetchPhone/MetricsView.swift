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
            var id: Date { date }
        }

        let week: [String: Any]
        let days: [Day]

        init(_ json: [String: Any]) {
            week = json["week"] as? [String: Any] ?? [:]
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            days = (json["days"] as? [[String: Any]] ?? []).compactMap { d in
                guard let date = (d["day"] as? String).flatMap(f.date(from:)) else { return nil }
                return Day(date: date, typed: d["typed_words"] as? Int ?? 0, dictated: d["dictated_words"] as? Int ?? 0,
                           latency: d["latency_median"] as? Double, autocorrected: d["autocorrected"] as? Int ?? 0)
            }
        }

        func number(_ key: String) -> Double? { (week[key] as? NSNumber)?.doubleValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let metrics {
                    hero(metrics)
                    section("Dictation") {
                        tile("To text", seconds(metrics.number("latency_median")), "median after release · 90% within \(seconds(metrics.number("latency_p90")))")
                        tile("Words", count(metrics.number("dictated_words")), "\(count(metrics.number("dictations"))) dictations · \(count(metrics.number("phone_dictations"))) from the iPhone")
                        tile("Changed after", percent(metrics.number("dictation_edit_rate")),
                             metrics.number("dictation_words_checked").map { $0 > 0 ? "of \(count($0)) dictated words seen to the end" : "no dictation seen to the end yet" } ?? "")
                        tile("Speaking", "\(count(metrics.number("speaking_wpm"))) wpm", "typing \(count(metrics.number("typing_wpm"))) wpm on the phone")
                    }
                    wordsChart(metrics)
                    latencyChart(metrics)
                    section("Keyboard") {
                        tile("Autocorrected", count(metrics.number("autocorrected")), "\(percent(metrics.number("autocorrect_undone_rate"))) taken back")
                        tile("Typos left", String(format: "%.1f", metrics.number("typos_left_per_100") ?? 0), "per 100 words typed")
                        tile("Backspaces", count(metrics.number("deletes_per_100")), "per 100 words typed")
                        tile("Suggestions", percent(metrics.number("suggestion_share")), "of the words typed")
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

    // MARK: - Parts

    private func hero(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This week").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            Text(duration(m.number("saved_minutes"))).font(.system(size: 46, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text("saved by speaking instead of typing").font(.subheadline).foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 18) {
                stat(percent(m.number("dictated_share")), "of words dictated")
                stat(count(m.number("dictated_words")), "words spoken")
                stat(count(m.number("typed_words")), "typed")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(LinearGradient(colors: [Color(red: 0.36, green: 0.27, blue: 0.95), Color(red: 0.62, green: 0.29, blue: 0.86)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
    }

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

    private func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f s", $0) } ?? "—" }

    private func duration(_ minutes: Double?) -> String {
        guard let minutes else { return "—" }
        return minutes >= 60 ? String(format: "%.0f h %02.0f min", (minutes / 60).rounded(.down), minutes.truncatingRemainder(dividingBy: 60))
            : "\(Int(minutes)) min"
    }
}
