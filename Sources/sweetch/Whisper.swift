import Foundation

/// Speech recognition on the local whisper.cpp build (Homebrew's), kept resident as `whisper-server`
/// so a listening costs a fraction of a second on the GPU rather than a model load. ffmpeg
/// normalises a recording to the 16 kHz mono WAV whisper reads.
///
/// The server is sweetch's child, on a loopback port. One left behind by a sweetch that was killed
/// is still the same server and is simply used.
enum Whisper {
    static let model = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/whisper-cpp/ggml-large-v3-turbo-q8_0.bin")
    private static let port = 8178
    private static let base = URL(string: "http://127.0.0.1:\(port)")!

    struct Word {
        let text: String
        let probability: Double
    }

    struct Heard {
        let text: String
        /// The language it was heard in: the one detected, or the one it was told.
        let language: String?
        /// Detection's probability for each language, when it detected.
        let languageProbabilities: [String: Double]
        let words: [Word]
        let json: URL
    }

    /// Short silences make whisper "hear" the closing lines of the subtitled videos it was trained
    /// on. When that's all a recording produced, nothing was said.
    private static let phantomPhrases: Set<String> = [
        "продолжение следует", "субтитры сделал dimatorzok", "субтитры создавал dimatorzok",
        "редактор субтитров асемкин корректор аегорова", "спасибо за просмотр",
        "thank you", "thanks for watching", "you",
    ]

    /// The missing pieces, in words, or nil when everything is in place.
    static func missing() -> String? {
        var gone: [String] = []
        if tool("ffmpeg") == nil { gone.append("ffmpeg") }
        if tool("whisper-server") == nil { gone.append("whisper-server") }
        if !FileManager.default.fileExists(atPath: model.path) { gone.append("the model at \(model.path)") }
        return gone.isEmpty ? nil : gone.joined(separator: ", ")
    }

    static func normalise(_ source: URL, to wav: URL) throws {
        try Subprocess.run(tool("ffmpeg") ?? "ffmpeg", [
            "-nostdin", "-loglevel", "error", "-y", "-i", source.path, "-ar", "16000", "-ac", "1", wav.path,
        ])
    }

    // MARK: - The server

    private static let lock = NSLock()
    private static var server: Process?

    /// Starts the server unless one answers already. Returns at once; `hear` waits for it.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = ensureRunning() }
    }

    static func shutDown() {
        lock.withLock { server?.terminate() }
    }

    /// Blocks until the server answers — up to the time it takes to load the model.
    private static func ensureRunning() -> Bool {
        if ping() { return true }
        lock.withLock {
            guard server?.isRunning != true, missing() == nil, let path = tool("whisper-server") else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-sns"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in log.info("whisper-server exited (\(p.terminationStatus, privacy: .public))") }
            do {
                try process.run()
                server = process
                log.info("whisper-server starting on :\(port, privacy: .public)")
            } catch {
                log.error("whisper-server failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if ping() { return true }
            usleep(200_000)
        }
        return false
    }

    private static func ping() -> Bool {
        var request = URLRequest(url: base)
        request.timeoutInterval = 0.5
        return (try? send(request)) != nil
    }

    // MARK: - Listening

    /// Listens to `wav` once — in `language`, or detecting it when nil — and saves the server's full
    /// answer to `<outputBase>.json`. Returns the text heard, empty when nothing was.
    static func hear(_ wav: URL, language: String?, prompt: String?, outputBase: URL) throws -> Heard {
        guard ensureRunning() else { throw Subprocess.Failure(description: "whisper-server is not answering") }
        var fields = ["language": language ?? "auto", "response_format": "verbose_json", "temperature": "0"]
        if let prompt, !prompt.isEmpty { fields["prompt"] = prompt }
        let boundary = "sweetch-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wav))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: base.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try send(request)
        let json = outputBase.appendingPathExtension("json")
        try? data.write(to: json)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Subprocess.Failure(description: "whisper-server answered with something other than JSON")
        }
        let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let probabilities = object["language_probabilities"] as? [String: Double] ?? [:]
        let detected = probabilities.max { $0.value < $1.value }?.key
        let segments = object["segments"] as? [[String: Any]] ?? []
        let phantom = isPhantom(text)
        return Heard(text: phantom ? "" : text,
                     language: language ?? detected,
                     languageProbabilities: language == nil ? probabilities : [:],
                     words: phantom ? [] : words(fromPieces: segments.flatMap { $0["words"] as? [[String: Any]] ?? [] }),
                     json: json)
    }

    private static func send(_ request: URLRequest) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(Subprocess.Failure(description: "no answer"))
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let data else {
                result = .failure(Subprocess.Failure(description: "whisper-server answered \(status)"))
                return
            }
            result = .success(data)
        }.resume()
        done.wait()
        return try result.get()
    }

    /// The server's "words" are word pieces: a piece that starts with a space opens a word, the rest
    /// continue it. A word is as certain as its least certain piece. Punctuation is part of the text,
    /// not of the word, so it is trimmed from what is reported and does not count towards the
    /// probability.
    private static func words(fromPieces pieces: [[String: Any]]) -> [Word] {
        var grouped: [[(String, Double)]] = []
        for token in pieces {
            guard let piece = token["word"] as? String, !piece.isEmpty, !piece.hasPrefix("[_") else { continue }
            if piece.hasPrefix(" ") || grouped.isEmpty { grouped.append([]) }
            grouped[grouped.count - 1].append((piece, token["probability"] as? Double ?? 1))
        }
        return grouped.compactMap { word in
            let text = word.map(\.0).joined()
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()«»…"))
            let scored = word.filter { $0.0.contains { $0.isLetter || $0.isNumber } }.map(\.1)
            guard !text.isEmpty, let least = scored.min() else { return nil }
            return Word(text: text, probability: least)
        }
    }

    private static func isPhantom(_ text: String) -> Bool {
        let bare = text.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        return bare.isEmpty || phantomPhrases.contains(bare)
    }

    /// A Homebrew tool by name. Apps launched by launchd don't get the shell's PATH.
    private static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
