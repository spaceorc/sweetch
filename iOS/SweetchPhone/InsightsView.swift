import Charts
import SwiftUI

/// What the numbers say about the user's hands and voice, from the Mac's `/insights`: where the
/// fingers land (fast, slow, by posture, the typos), how the phone is held, which letters are typed
/// for which, how typos grow with speed, what minding the offsets would do, how long dictations
/// take, and the words whisper is unsure of.
struct InsightsView: View {
    @State private var data: [String: Any]?
    @State private var problem: String?
    @State private var mode = "fast"

    private static let modes: [(String, String)] = [("fast", "Fast"), ("slow", "Slow"), ("thumbs", "Thumbs"), ("finger", "Finger"), ("errors", "Typos")]

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let data {
                    findings(data)
                    heatMap(data)
                    postures(data)
                    confusions(data).id("confusions")
                    tempo(data)
                    simulation(data).id("simulation")
                    latency(data)
                    unsure(data).id("unsure")
                } else if let problem {
                    ContentUnavailableView("No Mac in reach", systemImage: "hand.tap", description: Text(problem))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Insights")
        .task {
            await load()
            // `--insights-at <card>`: scrolled there, to look at it in the simulator.
            let arguments = ProcessInfo.processInfo.arguments
            if let i = arguments.firstIndex(of: "--insights-at"), i + 1 < arguments.count {
                try? await Task.sleep(for: .milliseconds(300))
                scroll.scrollTo(arguments[i + 1], anchor: .top)
            }
        }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            guard let mac = await Server.reachable() else { throw Failure("No Mac answers.") }
            data = try await mac.insights()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Findings

    private func findings(_ d: [String: Any]) -> some View {
        let lines = d["findings"] as? [String] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow).font(.footnote).padding(.top, 2)
                    Text(line).font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Heat map

    private func heatMap(_ d: [String: Any]) -> some View {
        let keys = (d["keys"] as? [[Any]] ?? []).compactMap { k -> (String, CGRect)? in
            guard let name = k.first as? String, k.count >= 5 else { return nil }
            let v = k[1...4].compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
            return v.count == 4 ? (name, CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) : nil
        }
        let cell = CGFloat((d["cell"] as? NSNumber)?.doubleValue ?? 4)
        let cells = ((d["heat"] as? [String: Any])?[mode] as? [[Int]]) ?? []
        let offsets = ((d["offsets"] as? [String: Any])?[mode] as? [String: [Double]]) ?? [:]
        let taps = d["taps"] as? [String: Any] ?? [:]
        let bounds = keys.reduce(CGRect.null) { $0.union($1.1) }
        let counts = Dictionary(uniqueKeysWithValues: Self.modes.map { ($0.0, cellsTotal(d, $0.0)) })
        return card("Where your fingers land") {
            Picker("Mode", selection: $mode) {
                ForEach(Self.modes, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            Canvas { context, size in
                guard !bounds.isNull, bounds.width > 0 else { return }
                let scale = size.width / bounds.width
                let map = { (p: CGPoint) in CGPoint(x: (p.x - bounds.minX) * scale, y: (p.y - bounds.minY) * scale) }
                for (_, rect) in keys {
                    let r = CGRect(origin: map(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale)).insetBy(dx: 2, dy: 2)
                    context.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(.white.opacity(0.07)))
                }
                let top = Double(cells.map { $0[2] }.max() ?? 1)
                var heat = context
                heat.blendMode = .plusLighter
                for c in cells where c.count == 3 {
                    let v = Double(c[2]) / top
                    let center = map(CGPoint(x: (CGFloat(c[0]) + 0.5) * cell, y: (CGFloat(c[1]) + 0.5) * cell))
                    let radius = cell * scale * 1.6
                    heat.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                              with: .color(Self.ramp(v).opacity(0.18 + 0.5 * v)))
                }
                for (name, rect) in keys {
                    let label = map(CGPoint(x: rect.minX + 8, y: rect.minY + 9))
                    context.draw(Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75)), at: label)
                    guard let o = offsets[name], o.count >= 3, o[2] >= 10 else { continue }
                    let from = map(CGPoint(x: rect.midX, y: rect.midY))
                    let to = map(CGPoint(x: rect.midX + o[0] * 2.5, y: rect.midY + o[1] * 2.5))
                    var arrow = Path()
                    arrow.move(to: from)
                    arrow.addLine(to: to)
                    context.stroke(arrow, with: .color(.cyan), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    context.fill(Path(ellipseIn: CGRect(x: from.x - 1.5, y: from.y - 1.5, width: 3, height: 3)), with: .color(.white))
                    let angle = atan2(to.y - from.y, to.x - from.x)
                    var head = Path()
                    head.move(to: to)
                    head.addLine(to: CGPoint(x: to.x - 5 * cos(angle - 0.5), y: to.y - 5 * sin(angle - 0.5)))
                    head.move(to: to)
                    head.addLine(to: CGPoint(x: to.x - 5 * cos(angle + 0.5), y: to.y - 5 * sin(angle + 0.5)))
                    context.stroke(head, with: .color(.cyan), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
            .aspectRatio(bounds.isNull ? 2.5 : bounds.width / bounds.height, contentMode: .fit)
            .background(Color(red: 0.08, green: 0.08, blue: 0.1), in: RoundedRectangle(cornerRadius: 12))
            Text(caption(mode, taps: taps, counted: counts[mode] ?? 0)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cellsTotal(_ d: [String: Any], _ mode: String) -> Int {
        (((d["heat"] as? [String: Any])?[mode] as? [[Int]]) ?? []).reduce(0) { $0 + ($1.count == 3 ? $1[2] : 0) }
    }

    private func caption(_ mode: String, taps: [String: Any], counted: Int) -> String {
        let arrows = "Arrows: where the finger lands on average, from the key's centre, ×2.5."
        switch mode {
        case "fast": return "\(counted) letter taps typed fast (under 0.35 s after the one before). " + arrows
        case "slow": return "\(counted) letter taps typed slowly (over 0.6 s after the one before). " + arrows
        case "thumbs": return "\(counted) taps in runs typed with two thumbs — large touches. " + arrows
        case "finger": return "\(counted) taps in runs typed with one finger — small touches. " + arrows
        default: return "\(counted) taps that became typos (put right by autocorrect or a suggestion). Arrows: from the key meant to where it was hit, ×2.5."
        }
    }

    /// Dark blue through magenta and orange to pale yellow, like a heat map should.
    private static func ramp(_ v: Double) -> Color {
        let stops: [(Double, Double, Double)] = [(0.2, 0.1, 0.6), (0.75, 0.15, 0.55), (1.0, 0.5, 0.1), (1.0, 0.95, 0.6)]
        let x = min(max(v, 0), 1) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2), f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    // MARK: - Postures

    private func postures(_ d: [String: Any]) -> some View {
        let p = d["postures"] as? [String: [String: Any]] ?? [:]
        func value(_ name: String, _ key: String) -> Double { (p[name]?[key] as? NSNumber)?.doubleValue ?? 0 }
        let rows: [(String, (String) -> String)] = [
            ("Runs of typing", { "\(Int(value($0, "runs")))" }),
            ("Taps", { "\(Int(value($0, "taps")))" }),
            ("Between taps", { String(format: "%.0f ms", value($0, "interval") * 1000) }),
            ("Same half ÷ other half", { String(format: "%.2f", value($0, "same_over_cross")) }),
            ("Typos per 100 taps", { String(format: "%.1f", value($0, "typos_per_100")) }),
        ]
        return card("How you hold the phone") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Label("Two thumbs", systemImage: "hands.and.sparkles").font(.caption.weight(.semibold))
                    Label("One finger", systemImage: "hand.point.up").font(.caption.weight(.semibold))
                }
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.1("thumbs")).font(.subheadline.monospacedDigit())
                        Text(row.1("finger")).font(.subheadline.monospacedDigit())
                    }
                }
            }
            Text("Told apart by the touches' size: a fingertip touches small, a thumb large. Thumbs gain from alternating hands — two taps on one half come slower than a change of half (over 1); one finger doesn't.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Confusions, tempo, simulation

    private struct Pair: Identifiable {
        let label: String
        let count: Int
        let fast: Double
        var id: String { label }
    }

    private func confusions(_ d: [String: Any]) -> some View {
        let pairs = (d["confusions"] as? [[Any]] ?? []).compactMap { c -> Pair? in
            guard c.count >= 4, let meant = c[0] as? String, let typed = c[1] as? String, let n = c[2] as? Int else { return nil }
            return Pair(label: "\(meant) → \(typed)", count: n, fast: (c[3] as? NSNumber)?.doubleValue ?? 0)
        }
        return card("Letters typed for others") {
            Chart(pairs) { pair in
                BarMark(x: .value("Times", pair.count), y: .value("Meant → typed", pair.label))
                    .foregroundStyle(Color.orange.gradient)
                    .annotation(position: .trailing) { Text("\(pair.count)").font(.caption2).foregroundStyle(.secondary) }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(pairs.count, 1)) * 24)
            Text("Meant → typed, from the words autocorrect or a suggestion put right.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private struct Band: Identifiable {
        let label: String
        let taps: Int
        let typos: Double
        var id: String { label }
    }

    private func tempo(_ d: [String: Any]) -> some View {
        let bands = (d["tempo"] as? [[Any]] ?? []).compactMap { b -> Band? in
            guard b.count >= 3, let label = b[0] as? String, let n = b[1] as? Int else { return nil }
            return Band(label: label, taps: n, typos: (b[2] as? NSNumber)?.doubleValue ?? 0)
        }
        return card("Typos by speed") {
            Chart(bands) { band in
                BarMark(x: .value("After the tap before", band.label), y: .value("Typos per 100 taps", band.typos))
                    .foregroundStyle(Color.purple.gradient)
                    .annotation(position: .top) { Text("\(band.taps)").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(height: 160)
            Text("Typos per 100 taps, by how soon each tap came after the one before; above each bar, how many taps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func simulation(_ d: [String: Any]) -> some View {
        let s = d["simulation"] as? [String: Any] ?? [:]
        let one = s["one_set"] as? [String: Int] ?? [:], posture = s["per_posture"] as? [String: Int] ?? [:]
        let typos = s["typos"] as? Int ?? 0
        return card("If the keys moved to meet your fingers") {
            HStack(spacing: 10) {
                outcome("One set of offsets", fixed: one["fixed"] ?? 0, broken: one["broken"] ?? 0)
                outcome("Offsets per posture", fixed: posture["fixed"] ?? 0, broken: posture["broken"] ?? 0)
            }
            Text("Of \(typos) typos typed fast, how many shifting each key's border by your offset would have put right — and how many right taps it would have made wrong. More broken than fixed: the offsets belong in the decoder's odds, not in the keys' borders.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func outcome(_ title: String, fixed: Int, broken: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("\(fixed)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("\(broken)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Voice

    private struct LatencyBand: Identifiable {
        let device: String
        let label: String
        let count: Int
        var id: String { device + label }
    }

    private func latency(_ d: [String: Any]) -> some View {
        let by = d["latency"] as? [String: [[Any]]] ?? [:]
        let bands = by.flatMap { device, rows in
            rows.compactMap { r -> LatencyBand? in
                guard r.count >= 2, let label = r[0] as? String, let n = r[1] as? Int else { return nil }
                return LatencyBand(device: device, label: label, count: n)
            }
        }
        // Each device as a share of its dictations: the Mac's thousands would flatten the phone's tens.
        let totals = Dictionary(grouping: bands, by: \.device).mapValues { $0.reduce(0) { $0 + $1.count } }
        let order = ["<0.5", "0.5–1", "1–1.5", "1.5–2", "2–3", "3–5", ">5"]
        return card("Release to text") {
            Chart(bands) { band in
                BarMark(x: .value("Seconds", band.label),
                        y: .value("Share", Double(band.count) / Double(max(totals[band.device] ?? 1, 1))))
                    .foregroundStyle(by: .value("Device", band.device))
                    .position(by: .value("Device", band.device))
            }
            .chartXScale(domain: order)
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text("\(Int(((value.as(Double.self) ?? 0) * 100).rounded()))%") } } }
            .chartForegroundStyleScale(["Mac": Color.indigo, "iPhone": Color.teal])
            .frame(height: 160)
            Text(totals.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value) dictations" }.joined(separator: " · ") + " — seconds from release to text, each device as a share of its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func unsure(_ d: [String: Any]) -> some View {
        let words = (d["unsure"] as? [[Any]] ?? []).compactMap { w -> (String, Int, Int)? in
            guard w.count >= 3, let word = w[0] as? String, let u = w[1] as? Int, let all = w[2] as? Int else { return nil }
            return (word, u, all)
        }
        return card("Words whisper is unsure of") {
            FlowLayout(spacing: 6) {
                ForEach(words, id: \.0) { word in
                    let share = Double(word.1) / Double(max(word.2, 1))
                    HStack(spacing: 4) {
                        Text(word.0).font(.subheadline)
                        Text("\(word.1)/\(word.2)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.orange.opacity(0.1 + 0.4 * share), in: Capsule())
                }
            }
            Text("Unsure (under 0.5) / heard, in the plain listening. Terms here are the prefix's to fix; a word unsure every time it's heard (\"thank\") is whisper hearing silence.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Words laid out in lines, wrapping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
