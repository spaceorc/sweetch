import SwiftUI
import UIKit

/// A talk about one dictation: the dictation on top — to copy, or to hear again on the Mac — and
/// what the user asks of it, by a button or in words («shorter», «only about the release», «in
/// English»): the model's versions under it, each one copied with a tap. Each ask works on the last
/// version. Kept on the phone, a file per dictation.
struct DictationChat: View {
    let item: DictationItem
    @StateObject private var copier = Copier()
    @State private var turns: [Turn] = []
    @State private var heard: String?
    @State private var input = ""
    @State private var asking = false
    @State private var hearing = false
    @State private var problem: String?
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    struct Turn: Codable, Identifiable, Hashable {
        var id = UUID()
        /// What the chat shows of the ask (a button's name), and what the model was told.
        let ask: String
        var instruction: String?
        var answer: String
    }

    /// The dictation as it stands — heard again, or as it came.
    private var original: String { heard ?? item.text }

    private static let actions: [(label: String, ask: String)] = [
        ("Summary", "Summarise it in a few sentences."),
        ("Shorter", "Make it shorter: the same points, fewer words."),
        ("Clean up", "Clean it up as written text: drop the filler and false starts, fix what was misheard, keep my words and meaning."),
        ("As a message", "Turn it into a message ready to send: clear, friendly, to the point."),
        ("To English", "Translate it into English."),
        ("На русский", "Переведи на русский."),
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        dictation
                        ForEach(turns) { turn in
                            ask(turn.ask)
                            answer(turn.answer)
                        }
                        if asking { ProgressView().frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8) }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns) { _, _ in withAnimation { scroll.scrollTo("end", anchor: .bottom) } }
                .onChange(of: asking) { _, _ in withAnimation { scroll.scrollTo("end", anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(item.date.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !turns.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear", systemImage: "trash") { turns = []; save() }
                    }
                }
            }
            .overlay(alignment: .bottom) { CopiedToast(copier: copier).padding(.bottom, 70) }
        }
        .onAppear {
            load()
            publishScreen()
        }
        .onDisappear { SharedState.appScreen = nil }
        .onChange(of: turns) { _, _ in publishScreen() }
    }

    /// What the keyboard tells the Mac a dictation into this chat is about: this one.
    private func publishScreen() {
        var screen: [String: Any] = ["screen": "dictation-chat", "about": String(original.prefix(3000))]
        if let last = turns.last?.answer { screen["last"] = String(last.prefix(1500)) }
        SharedState.appScreen = screen
    }

    // MARK: Parts

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item.device == "iPhone" ? "iphone" : "laptopcomputer")
                if !item.app.isEmpty { Text(item.app) }
                Spacer()
                if heard != nil {
                    Label("heard again", systemImage: "arrow.clockwise").font(.caption2)
                } else {
                    HeardBadge(item: item)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button { copier.copy(original) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                if item.recording {
                    Button { Task { await hearAgain() } } label: {
                        if hearing { ProgressView() } else { Label("Hear again", systemImage: "waveform") }
                    }
                    .buttonStyle(.bordered).disabled(hearing)
                }
                ShareLink(item: original) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.groupedSecondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func ask(_ text: String) -> some View {
        Text(text).font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func answer(_ text: String) -> some View {
        Button { copier.copy(text) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                Label("tap to copy", systemImage: "doc.on.doc").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.groupedSecondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .foregroundStyle(.primary)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copier.copy(text) }
            ShareLink(item: text)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.actions, id: \.label) { action in
                        Button(action.label) { Task { await send(action.label, instruction: action.ask) } }
                            .buttonStyle(.bordered).controlSize(.small).disabled(asking)
                    }
                }
                .padding(.horizontal)
            }
            HStack(spacing: 8) {
                TextField("Ask about it — «only about the release»", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.groupedSecondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    input = ""
                    Task { await send(text, instruction: text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(asking || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Asking

    private static let system = """
        You help the user with one of their dictations — text they spoke and speech recognition wrote \
        down — in a chat about it. Recognition may have misheard words: read through that to what was meant.
        When they ask for a version of it — summarise, shorten, keep only part, clean up, make it a \
        message, translate, rephrase — reply with that text alone, ready to paste: no preamble, no quotes, \
        no notes, in the dictation's language unless they ask for another. A later ask works on your last \
        version unless they say otherwise.
        When they ask something about it, or talk, answer briefly, as in a chat, in their language.
        """

    private func send(_ shown: String, instruction: String) async {
        guard !instruction.isEmpty else { return }
        typing = false
        asking = true
        problem = nil
        defer { asking = false }
        // The talk so far, each ask working on what came last: the dictation, then each version.
        let asks = turns.map { $0.instruction ?? $0.ask } + [instruction]
        var messages: [[String: String]] = [["role": "user", "content": "The dictation:\n\n\(original)\n\n\(asks[0])"]]
        for (turn, next) in zip(turns, asks.dropFirst()) {
            messages.append(["role": "assistant", "content": turn.answer])
            messages.append(["role": "user", "content": next])
        }
        do {
            let reply = try await LLMClient.complete(system: Self.system, messages: messages, maxTokens: 2000,
                                                     model: .smart, purpose: "dictation-chat", cache: true)
            turns.append(Turn(ask: shown, instruction: instruction, answer: reply.trimmingCharacters(in: .whitespacesAndNewlines)))
            save()
        } catch {
            problem = LLMClient.isConfigured ? error.localizedDescription : "No model credentials on the phone yet — open the app once with a Mac in reach."
        }
    }

    private func hearAgain() async {
        hearing = true
        problem = nil
        defer { hearing = false }
        do {
            heard = try await DictationHistory.shared.hearAgain(item)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Kept

    private var file: URL {
        URL.documentsDirectory.appendingPathComponent("chats", isDirectory: true).appendingPathComponent("\(item.id).json")
    }

    private func load() {
        if let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode([Turn].self, from: data) { turns = kept }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(turns).write(to: file)
    }
}
