import SwiftUI

/// What the keyboard learned about the user's emoji, to look at and take back: the ones hidden (for
/// a word, or for any), the skin tones chosen, the ones picked most — and everything reset to how
/// it came. The same app-group store the keyboard reads each time it appears (EmojiMemory).
struct EmojiView: View {
    @State private var memory = EmojiMemory.shared
    @State private var version = 0
    @State private var confirmReset = false

    private var hidden: [(entry: String, emoji: String, word: String)] {
        memory.hidden.sorted().compactMap { entry in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (entry, parts[1], parts[0]) : nil
        }
    }

    private var picks: [(emoji: String, count: Int)] {
        (memory.picked[EmojiMemory.any] ?? [:]).sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            Section {
                if hidden.isEmpty {
                    Text("Nothing hidden. Long-press an emoji on the keyboard's strip to hide it.").foregroundStyle(.secondary)
                }
                ForEach(hidden, id: \.entry) { item in
                    HStack {
                        Text(item.emoji).font(.title2)
                        Text(item.word == EmojiMemory.any ? "never" : "not for «\(item.word)»").foregroundStyle(.secondary)
                        Spacer()
                        Button("Show again") { memory.unhide(item.entry); version += 1 }
                    }
                }
            } header: { Text("Hidden") }

            Section {
                if memory.tones.isEmpty {
                    Text("None chosen. Long-press 👍, 🙏, 👋… to pick a skin tone.").foregroundStyle(.secondary)
                }
                ForEach(memory.tones.sorted { $0.key < $1.key }, id: \.key) { emoji, toned in
                    HStack {
                        Text("\(emoji)  →  \(toned)").font(.title3)
                        Spacer()
                        Button("Forget") { memory.forgetTone(of: emoji); version += 1 }
                    }
                }
            } header: { Text("Skin tones") }

            if !picks.isEmpty {
                Section {
                    Text(picks.map { "\($0.emoji) \($0.count)" }.joined(separator: "   "))
                } header: { Text("Picked most") } footer: {
                    Text("Emoji you pick come first for that word; so do those you put after a word from the system's emoji keyboard.")
                }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Forgets every pick, tone and hidden emoji — the keyboard offers them as they came.")
            }
        }
        .id(version)
        .navigationTitle("Emoji")
        .onAppear { memory.reload(); version += 1 }
        .confirmationDialog("Forget what the keyboard learned about your emoji?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { memory.reset(); version += 1 }
        }
    }
}
