import Foundation

/// What each call to a model cost: its tokens in and out (cache reads and writes apart), the model,
/// the provider that answered, and what it was for — settling a dictation, its prefix, a correction,
/// the glossary, a probe. The Mac keeps these in `llm-usage/<day>-<host>.jsonl` (synced between the
/// Macs), the iPhone sends them with its keyboard log; the metrics add them up (Metrics.llm).
///
/// Prices as flowra keeps them (anna-money/flowra, `flowra/llm/pricing/data`, synced from litellm):
/// $ per million tokens — Anthropic's, which Microsoft Foundry bills Claude at and Vertex too, with
/// Vertex's 10% on a location other than `global`; a prompt over a long-prompt threshold bills the
/// whole call at the long rates. The proxy is counted as Foundry (what it routes the fast model to).
enum LLMUsage {
    struct Price {
        let input, output, cacheRead, cacheWrite: Double
        /// A prompt (input and cache tokens) longer than this bills everything at `long`; 0: none.
        var longPrompt = 0
        var long: (input: Double, output: Double, cacheRead: Double, cacheWrite: Double)? = nil
    }

    static func price(_ model: LLMModel) -> Price {
        switch model {
        case .fast:   // Claude Haiku 5.5
            Price(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125,
                  longPrompt: 100_000, long: (0.50, 2.50, 0.05, 0.625))
        case .smart:  // Claude Sonnet 5.5
            Price(input: 2.00, output: 10.00, cacheRead: 0.10, cacheWrite: 2.50)
        }
    }

    static func name(_ model: LLMModel) -> String {
        switch model {
        case .fast: "haiku-5.5"
        case .smart: "sonnet-5.5"
        }
    }

    /// Where a call's record goes — set by the app: a file on the Mac, the keyboard log on the
    /// iPhone. Unset, nothing is kept.
    nonisolated(unsafe) static var sink: (([String: Any]) -> Void)?

    /// One call answered. `usage`: the response's (Anthropic's `usage`, or the proxy's), as it came.
    /// `regional`: served in a region at its uplift (Vertex outside `global`).
    static func record(model: LLMModel, provider: String, purpose: String, usage: [String: Any]?, seconds: Double,
                       regional: Bool = false) {
        func tokens(_ keys: String...) -> Int {
            for key in keys { if let n = (usage?[key] as? NSNumber)?.intValue { return n } }
            return 0
        }
        let input = tokens("input_tokens", "prompt_tokens")
        let output = tokens("output_tokens", "completion_tokens")
        let cacheRead = tokens("cache_read_input_tokens")
        let cacheWrite = tokens("cache_creation_input_tokens")
        let p = price(model)
        let isLong = p.longPrompt > 0 && input + cacheRead + cacheWrite > p.longPrompt
        let r = isLong ? p.long! : (p.input, p.output, p.cacheRead, p.cacheWrite)
        var cost = (Double(input) * r.0 + Double(output) * r.1 + Double(cacheRead) * r.2 + Double(cacheWrite) * r.3) / 1_000_000
        if regional { cost *= 1.1 }
        sink?([
            "t": (Date().timeIntervalSince1970 * 1000).rounded() / 1000,
            "model": name(model), "provider": provider, "purpose": purpose,
            "input": input, "output": output, "cache_read": cacheRead, "cache_write": cacheWrite,
            "cost": cost, "seconds": (seconds * 100).rounded() / 100, "counted": usage != nil,
        ])
    }
}
