import SwiftUI

/// The keyboard's microphone opens the app on this: listening at once, the words as they come, a
/// big button to stop. Going back to the app it came from stops it too — what's heard reaches the
/// keyboard there (from the Mac, or from the app itself), so speaking and swiping back is all.
struct DictationScreen: View {
    @ObservedObject private var dictation = Dictation.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Up, and listening unless it already is. `keyboard`: what the keyboard knew, for the context.
    static func open(keyboard: [String: Any]?, incognito: Bool = false) {
        let dictation = Dictation.shared
        dictation.screen = true
        if dictation.phase == .idle {
            dictation.keyboard = incognito ? nil : keyboard
            dictation.incognito = incognito
        }
        if dictation.phase == .idle { Task { _ = try? await dictation.toggle(waitingForScreenshot: false, source: "keyboard") } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if dictation.incognito { incognitoBadge }
                Spacer()
                Button {
                    dictation.screen = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36).background(.white.opacity(0.12), in: Circle())
                }
                .tint(.white)
            }
            .padding(.horizontal, 20)
            ScrollViewReader { scroll in
                ScrollView {
                    Text(words)
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .foregroundStyle(dictation.phase == .idle ? .white : .white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28).padding(.top, 24)
                        .id("words")
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: words)
                }
                .onChange(of: words) { scroll.scrollTo("words", anchor: .bottom) }
            }
            Spacer(minLength: 12)
            Text(hint).font(.callout).foregroundStyle(.white.opacity(0.55)).padding(.bottom, 24)
            button.padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: dictation.incognito
                                   ? [Color(white: 0.13), Color(white: 0.03)]   // no colour: nothing of this is kept
                                   : [Color(red: 0.07, green: 0.06, blue: 0.16), Color(red: 0.02, green: 0.02, blue: 0.05)],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            // Back in the app it came from: stopped there, heard in the background.
            if phase == .background, dictation.phase == .listening { Self.stopInBackground() }
            if phase == .background, dictation.phase == .idle { dictation.screen = false }
        }
    }

    /// Incognito, plainly: what it means, in a line.
    private var incognitoBadge: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Incognito", systemImage: "eye.slash")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
            Text("Heard on this phone only. Nothing kept, nothing sent.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var words: String {
        switch dictation.phase {
        case .listening: dictation.preview.isEmpty ? "Говорите…" : dictation.preview
        case .recognizing: dictation.preview.isEmpty ? "…" : dictation.preview
        case .idle: dictation.last.map { $0.isEmpty ? "Ничего не слышно" : $0 } ?? dictation.problem ?? ""
        }
    }

    private var hint: String {
        switch dictation.phase {
        case .listening: "Swipe back when done — it'll be typed there"
        case .recognizing: "Hearing…"
        case .idle: dictation.last.map { $0.isEmpty ? "" : "Swipe back — it's typed there" } ?? ""
        }
    }

    @ViewBuilder private var button: some View {
        switch dictation.phase {
        case .listening:
            TimelineView(.animation) { _ in
                let level = CGFloat(dictation.level)
                ZStack {
                    Circle().fill(.red.opacity(0.18)).frame(width: 96 + 70 * level, height: 96 + 70 * level)
                        .animation(.easeOut(duration: 0.08), value: level)
                    Button { Task { await dictation.stop(reason: "screen-stop") } } label: {
                        RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 30, height: 30)
                            .frame(width: 88, height: 88).background(.red, in: Circle())
                    }
                }
                .frame(width: 170, height: 170)
            }
        case .recognizing:
            ProgressView().controlSize(.large).tint(.white).frame(width: 170, height: 170)
        case .idle:
            Button { Task { _ = try? await dictation.toggle(waitingForScreenshot: false, source: "screen-mic") } } label: {
                Image(systemName: "mic.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 88, height: 88).background(.white.opacity(0.14), in: Circle())
            }
            .frame(width: 170, height: 170)
        }
    }

    /// Stopping as the app leaves the screen: iOS gives a moment to finish if asked.
    private static func stopInBackground() {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        Task { @MainActor in
            await Dictation.shared.stop(reason: "back-to-app")
            Dictation.shared.screen = false
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
