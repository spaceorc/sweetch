import Foundation

/// `sweetch --fill-probe <cases.json> <out.json>`: a dictated word the user marked as wrong, filled
/// in by the model — everything else in the text taken as right, the context and what each
/// recogniser heard as when it was settled (the dictation's `settlement.input`). The cases are
/// Tools/dictation/alternatives.py's `--cases`; the answer per case is the model's five guesses.
/// For a menu of what a clicked word could be instead (23 Oct).
enum FillProbe {
    private static let system = """
    A recording of the user's speech was transcribed. The user has marked one place in the final \
    text, shown as [___], as wrong; everything else in it is right. From the context they were in \
    and what the recognisers heard, work out what they actually said there. They speak Russian \
    with English technical terms, and write code identifiers as code (snake_case, kebab-case). \
    Reply with ONE JSON object: {"options": ["…", …]} — the five likeliest fillings for [___], \
    likeliest first, each written exactly as it should appear in the text, all different, none of \
    them what the transcript has there now.
    """

    static func run(_ input: URL, _ output: URL) {
        guard let data = try? Data(contentsOf: input),
              let cases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            print("no cases in \(input.path)")
            return
        }
        let model: LLMModel = ProcessInfo.processInfo.environment["SWEETCH_PROBE_SMART"] != nil ? .smart : .fast
        let done = DispatchSemaphore(value: 0)
        Task {
            var results: [[String: Any]] = []
            for (i, c) in cases.enumerated() {
                let dir = URL(fileURLWithPath: c["dir"] as? String ?? "")
                let session = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("session.json")))) as? [String: Any]
                let context = (session?["settlement"] as? [String: Any])?["input"] as? String ?? ""
                let words = c["words"] as? Int ?? 1
                let started = Date()
                var options: [String] = []
                do {
                    let reply = try await LLMClient.complete(system: system, messages: [["role": "user", "content": """
                        \(context)

                        <final_text>\(c["blanked"] as? String ?? "")</final_text>
                        [___] stands for \(words) word\(words == 1 ? "" : "s") in the transcript (the filling may differ in length). \
                        The transcript had: «\(c["old"] as? String ?? "")» — that is wrong.
                        """]], maxTokens: 200, model: model, purpose: "probe")
                    options = LLMJSON.object(reply)?["options"] as? [String] ?? []
                } catch {
                    print("case \(i): \(error)")
                }
                results.append(["truth": c["truth"] ?? "", "old": c["old"] ?? "", "options": options,
                                "seconds": Date().timeIntervalSince(started)])
                if i % 10 == 9 { print("\(i + 1)/\(cases.count)") }
            }
            try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]).write(to: output)
            done.signal()
        }
        done.wait()
    }
}
