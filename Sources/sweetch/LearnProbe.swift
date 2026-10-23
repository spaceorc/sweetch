import Foundation

/// `sweetch --learn-probe <cases.json> <out.json>`: settles stored dictations again, as the settling
/// does (Hearing's prompt, the input kept from the first time) — once as now, once told what the
/// user's corrections taught before each one (Tools/dictation/learn.py `--cases`) — so `--score`
/// can say whether telling the model helps. Haiku, four at a time.
enum LearnProbe {
    static func taught(_ input: String, learned: String) -> String {
        """
        \(input)

        <learned>
        Words this user says that the recognisers have heard wrong before, and how they were heard. \
        When the versions have one of these mishearings, the user most likely said the word on the left.
        \(learned)
        </learned>
        """
    }

    static func run(_ input: URL, _ output: URL) {
        guard let data = try? Data(contentsOf: input),
              let cases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            print("no cases in \(input.path)")
            return
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            var results = [[String: Any]](repeating: [:], count: cases.count)
            await withTaskGroup(of: (Int, [String: Any]).self) { group in
                var next = 0
                func start() {
                    guard next < cases.count else { return }
                    let i = next, c = cases[i]
                    next += 1
                    group.addTask {
                        let dir = URL(fileURLWithPath: c["dir"] as? String ?? "")
                        let session = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("session.json")))) as? [String: Any]
                        let block = (session?["settlement"] as? [String: Any])?["input"] as? String ?? ""
                        func settle(_ text: String) async -> String {
                            let reply = try? await LLMClient.complete(system: Hearing.system, messages: [["role": "user", "content": text]],
                                                                      maxTokens: 400, purpose: "probe")
                            return reply.flatMap { LLMJSON.object($0)?["text"] as? String } ?? ""
                        }
                        let plain = await settle(block)
                        // Nothing learned bears on it: told nothing, the same answer.
                        let learned = c["learned"] as? String ?? ""
                        let taught = learned.isEmpty ? plain : await settle(taught(block, learned: learned))
                        return (i, ["dir": dir.lastPathComponent, "plain": plain, "taught": taught,
                                    "truth": c["truth"] ?? "", "settled": c["settled"] ?? ""])
                    }
                }
                for _ in 0..<4 { start() }
                var finished = 0
                for await (i, result) in group {
                    results[i] = result
                    finished += 1
                    if finished % 25 == 0 { print("\(finished)/\(cases.count)") }
                    start()
                }
            }
            try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]).write(to: output)
            done.signal()
        }
        done.wait()
    }
}
