import SwiftUI
import UIKit

/// One dictation as the Mac keeps it (its DictationServer.dictations).
struct DictationItem: Identifiable, Hashable {
    let id: String
    let date: Date
    let text: String
    let app: String
    let device: String
    let seconds: Double?
    let handoff: String?

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let text = json["text"] as? String else { return nil }
        self.id = id
        date = Date(timeIntervalSince1970: json["t"] as? Double ?? 0)
        self.text = text
        app = json["app"] as? String ?? ""
        device = json["device"] as? String ?? "Mac"
        seconds = json["seconds"] as? Double
        handoff = json["handoff"] as? String
    }
}

/// The dictations, kept on the Macs — from this phone and from them — fetched from the Mac that
/// answers; the last ones fetched kept here too, for when none does.
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()

    @Published private(set) var items: [DictationItem] = []
    @Published private(set) var problem: String?
    @Published private(set) var loading = false
    @Published private(set) var fetched: Date?

    private static var cache: URL { URL.cachesDirectory.appendingPathComponent("dictations.json") }

    init() {
        if let data = try? Data(contentsOf: Self.cache),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items = list.compactMap(DictationItem.init)
        }
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        guard let mac = await Server.reachable() else {
            problem = "No Mac answers — the last ones fetched."
            return
        }
        do {
            let list = try await mac.dictations(limit: 300)
            items = list.compactMap(DictationItem.init)
            problem = nil
            fetched = Date()
            if let data = try? JSONSerialization.data(withJSONObject: list) { try? data.write(to: Self.cache) }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Copies a dictation, with a tap felt and a word shown.
@MainActor
final class Copier: ObservableObject {
    @Published var copied: String?

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = text
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copied == text { copied = nil }
        }
    }
}

/// A dictation in a list: what was said, when, into what.
struct DictationRow: View {
    let item: DictationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text).lineLimit(3)
            HStack(spacing: 6) {
                Image(systemName: item.device == "iPhone" ? "iphone" : "laptopcomputer")
                Text(item.date.formatted(Calendar.current.isDateInToday(item.date) ? .dateTime.hour().minute()
                                         : .dateTime.day().month().hour().minute()))
                if !item.app.isEmpty, item.app != "iPhone" { Text("· \(item.app)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Every dictation, newest first, by day: a tap copies one; search, and which device.
struct HistoryView: View {
    @ObservedObject private var history = DictationHistory.shared
    @StateObject private var copier = Copier()
    @State private var query = ""
    @State private var device = "All"

    private var shown: [DictationItem] {
        history.items.filter { item in
            (device == "All" || (device == "iPhone") == (item.device == "iPhone"))
                && (query.isEmpty || item.text.localizedCaseInsensitiveContains(query) || item.app.localizedCaseInsensitiveContains(query))
        }
    }

    private var days: [(Date, [DictationItem])] {
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
        return groups.sorted { $0.key > $1.key }
    }

    var body: some View {
        List {
            Section {
                Picker("Device", selection: $device) { ForEach(["All", "iPhone", "Mac"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                if let problem = history.problem {
                    Label(problem, systemImage: "wifi.slash").font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(days, id: \.0) { day, items in
                Section(day.formatted(Calendar.current.isDateInToday(day) ? .dateTime.weekday(.wide) : .dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(items) { item in
                        Button { copier.copy(item.text) } label: { DictationRow(item: item) }
                            .foregroundStyle(.primary)
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { copier.copy(item.text) }
                                ShareLink(item: item.text)
                            }
                            .swipeActions(edge: .leading) {
                                Button("Copy", systemImage: "doc.on.doc") { copier.copy(item.text) }.tint(.teal)
                            }
                    }
                }
            }
            if history.items.isEmpty, !history.loading {
                ContentUnavailableView("No dictations yet", systemImage: "mic", description: Text("They come from the Mac that answers."))
            }
        }
        .searchable(text: $query, prompt: "What you said")
        .navigationTitle("History")
        .refreshable { await history.refresh() }
        .task { await history.refresh() }
        .overlay(alignment: .bottom) { CopiedToast(copier: copier) }
    }
}

/// «Copied» for a moment at the bottom.
struct CopiedToast: View {
    @ObservedObject var copier: Copier

    var body: some View {
        if copier.copied != nil {
            Label("Copied", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
