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
    /// Who heard it: "mac", "phone" (whisper here), "apple" (Apple's hearing alone), "mac-again".
    let heardOn: String
    /// Its recording is kept: it can be heard again.
    let recording: Bool
    /// Only on this phone yet — no Mac has it.
    let local: Bool
    /// What it said before it was heard again.
    let before: String?

    /// Heard without a Mac: likely worse.
    var heardOnPhone: Bool { heardOn == "phone" || heardOn == "apple" }

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let text = json["text"] as? String else { return nil }
        self.id = id
        date = Date(timeIntervalSince1970: json["t"] as? Double ?? 0)
        self.text = text
        app = json["app"] as? String ?? ""
        device = json["device"] as? String ?? "Mac"
        seconds = json["seconds"] as? Double
        handoff = json["handoff"] as? String
        heardOn = json["heard_on"] as? String ?? "mac"
        recording = json["recording"] as? Bool ?? false
        local = json["local"] as? Bool ?? false
        before = json["before"] as? String
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

    private var cachedList: [[String: Any]] {
        (try? Data(contentsOf: Self.cache)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
    }

    init() {
        if let data = try? Data(contentsOf: Self.cache),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items = Self.merged(list)
        }
    }

    /// The Macs' list with what only this phone has yet, newest first.
    private static func merged(_ list: [[String: Any]]) -> [DictationItem] {
        let fromMac = list.compactMap(DictationItem.init)
        let known = Set(fromMac.map(\.id))
        let local = PhoneDictations.unsent().compactMap(DictationItem.init).filter { !known.contains($0.id) }
        return (fromMac + local).sorted { $0.date > $1.date }
    }

    /// Heard again on the Mac — sent there first if only the phone has it; the list then refreshed.
    func hearAgain(_ item: DictationItem) async throws -> String {
        guard let mac = await Server.reachable() else { throw Failure("No Mac answers.") }
        if item.local {
            let folder = PhoneDictations.dir.appendingPathComponent(item.id)
            guard try await PhoneDictations.send(folder, to: mac) else { throw Failure("The Mac didn't take it.") }
            try? FileManager.default.removeItem(at: folder)
        }
        let text = try await mac.hearAgain(item.id)
        await refresh()
        return text
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        await PhoneDictations.upload()
        guard let mac = await Server.reachable() else {
            problem = "No Mac answers — the last ones fetched."
            items = Self.merged(cachedList)
            return
        }
        do {
            let list = try await mac.dictations(limit: 300)
            items = Self.merged(list)
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
            Text(item.text).lineLimit(3).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Image(systemName: item.device == "iPhone" ? "iphone" : "laptopcomputer")
                Text(item.date.formatted(Calendar.current.isDateInToday(item.date) ? .dateTime.hour().minute()
                                         : .dateTime.day().month().hour().minute()))
                if !item.app.isEmpty, item.app != "iPhone" { Text("· \(item.app)") }
                if item.heardOnPhone { Text("· heard on the phone").foregroundStyle(.orange) }
                if item.heardOn == "mac-again" { Text("· heard again") }
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
    @State private var open: DictationItem?

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
                        Button { open = item } label: { DictationRow(item: item) }
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
        .sheet(item: $open) { item in DictationDetail(item: item) }
    }
}

/// One dictation: all of it, to copy or share — and, its recording kept, heard again on the Mac.
struct DictationDetail: View {
    let item: DictationItem
    @StateObject private var copier = Copier()
    @State private var text: String?
    @State private var hearing = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(text ?? item.text).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Image(systemName: item.device == "iPhone" ? "iphone" : "laptopcomputer")
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        if !item.app.isEmpty { Text("· \(item.app)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if item.heardOnPhone, text == nil {
                        Label(item.heardOn == "apple" ? "Heard by Apple's dictation alone — no Mac was in reach."
                              : "Heard on the phone — no Mac was in reach.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let before = text != nil ? item.text : item.before {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Before").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(before).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }

                    Button { copier.copy(text ?? item.text) } label: {
                        Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if item.recording {
                        Button {
                            Task { await hearAgain() }
                        } label: {
                            HStack {
                                if hearing { ProgressView() } else { Image(systemName: "waveform") }
                                Text(hearing ? "Hearing on the Mac…" : "Hear again on the Mac")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(hearing)
                    }
                    ShareLink(item: text ?? item.text) { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                .padding()
            }
            .navigationTitle("Dictation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay(alignment: .bottom) { CopiedToast(copier: copier) }
        }
        .presentationDetents([.medium, .large])
    }

    private func hearAgain() async {
        hearing = true
        problem = nil
        defer { hearing = false }
        do {
            text = try await DictationHistory.shared.hearAgain(item)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            problem = error.localizedDescription
        }
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
