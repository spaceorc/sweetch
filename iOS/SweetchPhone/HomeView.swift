import SwiftUI

/// The app's first screen: which Mac hears, a big button to dictate, today in numbers, and the
/// last dictations — a tap copies one.
struct HomeView: View {
    @ObservedObject private var dictation = Dictation.shared
    @ObservedObject private var history = DictationHistory.shared
    @StateObject private var copier = Copier()
    @State private var mac: Server??
    @State private var today: [String: Any] = [:]
    @State private var week: [String: Any] = [:]
    @State private var open: DictationItem?

    private static let mint = Color(red: 0.25, green: 0.72, blue: 0.62)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                status
                dictate
                numbers
                recent
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.grouped)
        .navigationTitle("Today")
        .refreshable { await load() }
        .task { await load() }
        .overlay(alignment: .bottom) { CopiedToast(copier: copier) }
        .sheet(item: $open) { item in DictationChat(item: item) }
    }

    private func load() async {
        async let server = Server.reachable()
        mac = .some(await server)
        await history.refresh()
        if let found = mac ?? nil, let metrics = try? await found.metrics() {
            today = (metrics["days"] as? [[String: Any]])?.last ?? [:]
            week = metrics["week"] as? [String: Any] ?? [:]
        }
    }

    /// Which Mac the phone reaches: the Mac mini or the MacBook, by its address.
    private var macName: String? {
        guard case .some(.some(let server)) = mac else { return nil }
        return server.address.contains("mini") || server.address.contains("100.64.10.10") ? "Mac mini" : "MacBook"
    }

    private var status: some View {
        HStack(spacing: 12) {
            Circle().fill(mac == nil ? Color.gray : macName == nil ? Color.orange : Self.mint).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac == nil ? "Looking for a Mac…" : macName.map { "Heard on the \($0)" } ?? "No Mac answers")
                    .font(.subheadline.weight(.semibold))
                Text(macName == nil && mac != nil ? "Dictation is heard on the phone meanwhile; Tailscale off, or a VPN in the way?"
                     : "The keyboard's log and the history come from it")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.groupedSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var dictate: some View {
        Button {
            Task { _ = try? await dictation.toggle(waitingForScreenshot: false, source: "app-button") }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: dictation.phase == .listening ? "stop.fill" : "mic.fill").font(.system(size: 30, weight: .semibold))
                Text(dictation.phase == .listening ? "Stop" : dictation.phase == .recognizing ? "Hearing…" : "Dictate")
                    .font(.headline)
                if dictation.phase == .listening, !dictation.preview.isEmpty {
                    Text(dictation.preview).font(.footnote).lineLimit(2).multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(dictation.phase == .listening ? Color.red.gradient : Self.mint.gradient,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .disabled(dictation.phase == .recognizing)
    }

    private func number(_ value: Any?, _ label: String, format: String = "%.0f") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((value as? NSNumber).map { String(format: format, $0.doubleValue) } ?? "—")
                .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var numbers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today").font(.headline)
            HStack {
                number(today["dictations"], "dictations")
                number(today["dictated_words"], "words said")
                number(today["typed_words"], "words typed")
            }
            Divider()
            Text("This week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                number(week["dictated_words"], "words said")
                number(week["typed_words"], "words typed")
                number(week["latency_median"], "typical wait, s", format: "%.1f")
            }
        }
        .padding(16)
        .background(Color.groupedSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Last dictations").font(.headline)
                Spacer()
                NavigationLink("All") { HistoryView() }.font(.subheadline)
            }
            .padding(.bottom, 6)
            if let problem = dictation.problem { Text(problem).font(.footnote).foregroundStyle(.red).padding(.bottom, 6) }
            ForEach(history.items.prefix(6)) { item in
                Divider()
                DictationRow(item: item, open: { open = item }, copy: { copier.copy(item.text) })
                    .padding(.vertical, 6)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { copier.copy(item.text) }
                        ShareLink(item: item.text)
                    }
            }
            if history.items.isEmpty {
                Text(dictation.last ?? "None yet.").foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(Color.groupedSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
