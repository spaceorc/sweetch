import Foundation
import Security

/// Mints and caches a GCP OAuth2 access token from a service-account key, for calling
/// Anthropic models on Vertex AI. Implemented directly on Security.framework (JWT-bearer
/// flow: sign an RS256 assertion, exchange it at oauth2.googleapis.com) — no GCP SDK.
enum VertexAuth {
    struct ServiceAccount {
        let clientEmail: String
        let privateKeyPEM: String

        /// Parse from the base64-encoded service-account JSON we keep in the env file.
        init?(base64JSON: String) {
            guard let data = Data(base64Encoded: base64JSON.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = obj["client_email"] as? String,
                  let key = obj["private_key"] as? String else { return nil }
            self.clientEmail = email
            self.privateKeyPEM = key
        }
    }

    enum AuthError: Error {
        case badPrivateKey
        case signFailed
        case tokenRequestFailed(Int, String)
    }

    private static let scope = "https://www.googleapis.com/auth/cloud-platform"
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// Token cache. An actor rather than a lock: `accessToken` is called from async code,
    /// where NSLock is unavailable (a hard error under Swift 6).
    private actor Cache {
        private var token: String?
        private var until: Date = .distantPast

        func get(_ sa: ServiceAccount) async throws -> String {
            if let token, Date() < until { return token }
            let (fresh, ttl) = try await VertexAuth.mint(sa)
            token = fresh
            until = Date().addingTimeInterval(max(60, ttl - 60))   // refresh a minute early
            log.info("vertex: minted access token (ttl \(Int(ttl), privacy: .public)s)")
            return fresh
        }
    }

    private static let cache = Cache()

    /// Cached access token; refreshed automatically shortly before it expires.
    static func accessToken(_ sa: ServiceAccount) async throws -> String {
        try await cache.get(sa)
    }

    // MARK: - JWT-bearer exchange

    private static func mint(_ sa: ServiceAccount) async throws -> (String, TimeInterval) {
        let now = Int(Date().timeIntervalSince1970)
        let header = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": sa.clientEmail,
            "scope": scope,
            "aud": tokenURL.absoluteString,
            "iat": now,
            "exp": now + 3600,
        ]
        let signingInput = try base64URL(JSONSerialization.data(withJSONObject: header))
            + "." + base64URL(JSONSerialization.data(withJSONObject: claims))
        let signature = try sign(Data(signingInput.utf8), pem: sa.privateKeyPEM)
        let assertion = signingInput + "." + base64URL(signature)

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=" + assertion
        req.httpBody = form.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw AuthError.tokenRequestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
        let ttl = (obj["expires_in"] as? Double) ?? 3600
        return (token, ttl)
    }

    // MARK: - RS256 signing

    private static func sign(_ message: Data, pem: String) throws -> Data {
        let key = try rsaPrivateKey(fromPEM: pem)
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                              message as CFData, &error) else {
            throw AuthError.signFailed
        }
        return sig as Data
    }

    /// Build a SecKey from a PEM private key. Service-account keys are PKCS#8, which
    /// SecKeyCreateWithData doesn't take — so unwrap it down to the PKCS#1 RSAPrivateKey.
    private static func rsaPrivateKey(fromPEM pem: String) throws -> SecKey {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\n", with: "")   // JSON-escaped newlines
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: base64) else { throw AuthError.badPrivateKey }

        let pkcs1 = (try? unwrapPKCS8(der)) ?? der
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary, &error) else {
            throw AuthError.badPrivateKey
        }
        return key
    }

    /// PKCS#8 PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE,
    ///                                      privateKey OCTET STRING (the PKCS#1 key) }
    private static func unwrapPKCS8(_ der: Data) throws -> Data {
        var i = der.startIndex
        func byte() throws -> UInt8 {
            guard i < der.endIndex else { throw AuthError.badPrivateKey }
            defer { i = der.index(after: i) }
            return der[i]
        }
        func length() throws -> Int {
            let first = try byte()
            if first & 0x80 == 0 { return Int(first) }
            var n = 0
            for _ in 0..<Int(first & 0x7F) { n = n << 8 | Int(try byte()) }
            return n
        }
        func expect(_ tag: UInt8) throws -> Int {
            guard try byte() == tag else { throw AuthError.badPrivateKey }
            return try length()
        }

        _ = try expect(0x30)                       // outer SEQUENCE
        let versionLen = try expect(0x02)          // version INTEGER
        i = der.index(i, offsetBy: versionLen)
        let algLen = try expect(0x30)              // AlgorithmIdentifier SEQUENCE
        i = der.index(i, offsetBy: algLen)
        let keyLen = try expect(0x04)              // privateKey OCTET STRING
        guard der.distance(from: i, to: der.endIndex) >= keyLen else { throw AuthError.badPrivateKey }
        return der.subdata(in: i..<der.index(i, offsetBy: keyLen))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
