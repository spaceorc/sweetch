import Foundation

/// Speech recognition on the local whisper.cpp build (Homebrew's `whisper-cli`), the way Gemma's
/// prototype drives it: ffmpeg normalises the recording to the 16 kHz mono WAV whisper reads, and
/// `-ojf` writes JSON with a probability for every token.
///
/// The model is loaded on every call — about a second on Apple silicon. Keeping it resident
/// (`whisper-server`) can come once there is more than one listening per recording.
enum Whisper {
    static let model = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/whisper-cpp/ggml-large-v3-turbo-q8_0.bin")

    struct Listening {
        let language: String
        let prompt: String?
    }

    struct Heard {
        let text: String
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
        if tool("whisper-cli") == nil { gone.append("whisper-cli") }
        if !FileManager.default.fileExists(atPath: model.path) { gone.append("the model at \(model.path)") }
        return gone.isEmpty ? nil : gone.joined(separator: ", ")
    }

    static func normalise(_ source: URL, to wav: URL) throws {
        try Subprocess.run(tool("ffmpeg") ?? "ffmpeg", [
            "-nostdin", "-loglevel", "error", "-y", "-i", source.path, "-ar", "16000", "-ac", "1", wav.path,
        ])
    }

    /// Writes `<outputBase>.json` and returns the text heard, empty when nothing was.
    static func hear(_ wav: URL, _ listening: Listening, outputBase: URL) throws -> Heard {
        var args = ["-m", model.path, "-f", wav.path, "-l", listening.language, "-sns", "-ojf", "-of", outputBase.path, "-np"]
        if let prompt = listening.prompt, !prompt.isEmpty { args += ["--prompt", prompt] }
        try Subprocess.run(tool("whisper-cli") ?? "whisper-cli", args, timeout: 120)
        let json = outputBase.appendingPathExtension("json")
        let data = try Data(contentsOf: json)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let segments = object?["transcription"] as? [[String: Any]] ?? []
        let text = segments
            .map { ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Heard(text: isPhantom(text) ? "" : text, json: json)
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
