import Foundation

struct LLMConfig {
    let resource: String
    let apiKey: String
    let model: String

    var endpoint: URL? {
        URL(string: "https://\(resource).services.ai.azure.com/anthropic/v1/messages")
    }
}

enum LLMError: Error {
    case notConfigured
    case badResponse(Int, String)
    case decode
    case emptyResult
}

/// Minimal Anthropic Messages API client for Azure AI Foundry.
/// Endpoint / auth / model are all verified against the anna Foundry resource:
/// - URL:   https://<resource>.services.ai.azure.com/anthropic/v1/messages
/// - Auth:  x-api-key header (NOT Bearer, NOT Azure api-key) + anthropic-version
/// - model: the DEPLOYMENT name (full dated ID), not a short alias.
enum LLMClient {
    /// The one deployment we use — fast + cheap, enough for typo/layout correction.
    static let model = "claude-haiku-4-5-20251001"

    /// Loaded once from `sweetch.env` bundled into the app's Resources (copied from
    /// the repo `.env` by the Makefile). nil if the file or keys are missing.
    static let config: LLMConfig? = {
        guard let url = Bundle.main.url(forResource: "sweetch", withExtension: "env"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("LLM: sweetch.env not found in app bundle")
            return nil
        }
        var kv: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
            }
            kv[key] = val
        }
        guard let res = kv["SWEETCH_AZURE_RESOURCE"], !res.isEmpty,
              let key = kv["SWEETCH_AZURE_API_KEY"], !key.isEmpty else {
            log.error("LLM: SWEETCH_AZURE_RESOURCE / SWEETCH_AZURE_API_KEY missing in env")
            return nil
        }
        return LLMConfig(resource: res, apiKey: key, model: model)
    }()

    static var isConfigured: Bool { config != nil }

    /// Messages API call. `messages` is a role/content conversation. Returns the
    /// concatenated assistant text.
    static func complete(system: String, messages: [[String: String]], maxTokens: Int = 600, model: String? = nil) async throws -> String {
        guard let config, let url = config.endpoint else { throw LLMError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model ?? config.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw LLMError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw LLMError.decode
        }
        let text = content
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.emptyResult }
        return text
    }
}
