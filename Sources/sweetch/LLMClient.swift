import Foundation

/// Logical models, mapped per provider. Ids mirror what flowra uses in production
/// (`claude-haiku-4-5@20251001`, `claude-sonnet-4-5@20250929` on Vertex).
enum LLMModel {
    case fast    // per-keystroke correction
    case smart   // glossary distillation

    var vertexID: String {
        switch self {
        case .fast:  return "claude-haiku-4-5@20251001"
        case .smart: return "claude-sonnet-4-5@20250929"
        }
    }

    /// Azure Foundry addresses models by DEPLOYMENT name (no `@`).
    var azureDeployment: String {
        switch self {
        case .fast:  return "claude-haiku-4-5-20251001"
        case .smart: return "claude-sonnet-4-5-20250929"
        }
    }
}

enum LLMError: Error {
    case notConfigured
    case badResponse(Int, String)
    case decode
    case emptyResult
}

/// LLM client with an ordered provider chain, tried in this order:
///
/// 1. **ANNA LLM proxy** (`POST /api/chat`) — plain HTTP, no key, but only reachable on the
///    ANNA network/VPN. Same thing anna-gemma uses. Primary.
/// 2. **Anthropic on Vertex AI** — service-account auth (same shape flowra uses). Works
///    anywhere, so it covers being off-VPN.
/// 3. **Azure AI Foundry** — legacy; only useful while a valid Foundry key exists.
///
/// Credentials come from `sweetch.env` bundled into the app's Resources (copied from the
/// repo `.env` by the Makefile).
enum LLMClient {
    struct Config {
        var proxyURL: String?
        var vertexProject: String?
        var vertexLocation: String?
        var vertexSA: VertexAuth.ServiceAccount?
        var azureResource: String?
        var azureKey: String?

        var hasProxy: Bool { proxyURL != nil }
        var hasVertex: Bool { vertexProject != nil && vertexLocation != nil && vertexSA != nil }
        var hasAzure: Bool { azureResource != nil && azureKey != nil }
    }

    static let config: Config? = {
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
            if !val.isEmpty { kv[key] = val }
        }

        var cfg = Config()
        cfg.proxyURL = kv["SWEETCH_PROXY_URL"]
        cfg.vertexProject = kv["SWEETCH_VERTEX_PROJECT"]
        cfg.vertexLocation = kv["SWEETCH_VERTEX_LOCATION"]
        if let b64 = kv["SWEETCH_VERTEX_CREDENTIALS"] {
            cfg.vertexSA = VertexAuth.ServiceAccount(base64JSON: b64)
            if cfg.vertexSA == nil { log.error("LLM: SWEETCH_VERTEX_CREDENTIALS didn't parse") }
        }
        cfg.azureResource = kv["SWEETCH_AZURE_RESOURCE"]
        cfg.azureKey = kv["SWEETCH_AZURE_API_KEY"]

        guard cfg.hasProxy || cfg.hasVertex || cfg.hasAzure else {
            log.error("LLM: no usable credentials in sweetch.env")
            return nil
        }
        log.info("LLM: providers — proxy=\(cfg.hasProxy, privacy: .public) vertex=\(cfg.hasVertex, privacy: .public) azure=\(cfg.hasAzure, privacy: .public)")
        return cfg
    }()

    static var isConfigured: Bool { config != nil }

    /// Call the model, walking the provider chain (proxy → vertex → azure). Any failure from
    /// one provider falls through to the next, so being off-VPN (proxy unreachable) or a
    /// revoked key degrades gracefully instead of breaking correction.
    static func complete(system: String,
                         messages: [[String: String]],
                         maxTokens: Int = 600,
                         model: LLMModel = .fast) async throws -> String {
        guard let config else { throw LLMError.notConfigured }

        var attempts: [(name: String, call: () async throws -> String)] = []
        if config.hasProxy {
            attempts.append(("proxy", { try await callProxy(config: config, system: system, messages: messages,
                                                            maxTokens: maxTokens, model: model) }))
        }
        if config.hasVertex {
            attempts.append(("vertex", { try await callVertex(config: config, system: system, messages: messages,
                                                              maxTokens: maxTokens, model: model) }))
        }
        if config.hasAzure {
            attempts.append(("azure", { try await callAzure(config: config, system: system, messages: messages,
                                                            maxTokens: maxTokens, model: model) }))
        }
        guard !attempts.isEmpty else { throw LLMError.notConfigured }

        var lastError: Error = LLMError.notConfigured
        for (index, attempt) in attempts.enumerated() {
            do {
                return try await attempt.call()
            } catch {
                lastError = error
                let next = index + 1 < attempts.count ? attempts[index + 1].name : "none"
                log.error("LLM: \(attempt.name, privacy: .public) failed (\(String(describing: error), privacy: .public)), next=\(next, privacy: .public)")
            }
        }
        throw lastError
    }

    // MARK: - ANNA LLM proxy (primary)

    private static func callProxy(config: Config, system: String, messages: [[String: String]],
                                  maxTokens: Int, model: LLMModel) async throws -> String {
        guard let base = config.proxyURL,
              let url = URL(string: base.hasSuffix("/") ? base + "api/chat" : base + "/api/chat") else {
            throw LLMError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("sweetch", forHTTPHeaderField: "X-Service-Name")
        // The proxy takes the system prompt as a `system`-role message (not a separate field),
        // and routes Anthropic models through provider VERTEX_AI.
        let allMessages = [["role": "system", "content": system]] + messages
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "VERTEX_AI",
            "model": model.vertexID,
            "max_tokens": maxTokens,
            "messages": allMessages,
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw LLMError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }
        // Envelope: {"data": {"message": "...", "usage": {...}}, "error": {}}
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decode
        }
        if let err = obj["error"] as? [String: Any], !err.isEmpty {
            throw LLMError.badResponse(code, String(describing: err))
        }
        guard let payload = obj["data"] as? [String: Any],
              let message = payload["message"] as? String else { throw LLMError.decode }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.emptyResult }
        return text
    }

    // MARK: - Vertex AI (primary)

    private static func callVertex(config: Config, system: String, messages: [[String: String]],
                                   maxTokens: Int, model: LLMModel) async throws -> String {
        guard let project = config.vertexProject,
              let location = config.vertexLocation,
              let sa = config.vertexSA else { throw LLMError.notConfigured }

        let token: String
        do {
            token = try await VertexAuth.accessToken(sa)
        } catch {
            // Surface as an auth failure so `complete` can fall through to Azure.
            throw LLMError.badResponse(401, "vertex token mint failed: \(error)")
        }

        guard let url = URL(string: "https://\(location)-aiplatform.googleapis.com/v1/projects/\(project)"
                            + "/locations/\(location)/publishers/anthropic/models/\(model.vertexID):rawPredict") else {
            throw LLMError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // On Vertex the model lives in the URL; the body carries anthropic_version instead.
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "anthropic_version": "vertex-2023-10-16",
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ])
        return try await send(req)
    }

    // MARK: - Azure AI Foundry (fallback)

    private static func callAzure(config: Config, system: String, messages: [[String: String]],
                                 maxTokens: Int, model: LLMModel) async throws -> String {
        guard let resource = config.azureResource, let key = config.azureKey,
              let url = URL(string: "https://\(resource).services.ai.azure.com/anthropic/v1/messages") else {
            throw LLMError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.azureDeployment,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ])
        return try await send(req)
    }

    // MARK: - Shared response handling

    private static func send(_ req: URLRequest) async throws -> String {
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
