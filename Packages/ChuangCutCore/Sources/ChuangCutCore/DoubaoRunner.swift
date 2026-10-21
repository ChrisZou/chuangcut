import Foundation

/// Transcribes with Volcengine's Doubao Seed-ASR (recording-file recognition, flash endpoint). Whisper tidies
/// speech into subtitles and drops restarts and repeated phrases; Seed-ASR writes down what was said, with a
/// timestamp for every character, so retake detection sees every take.
public struct DoubaoRunner {
    public static let endpoint = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    public static let resource = "volc.seedasr.auc"
    public var apiKey: String
    public var hotwordTable: String?
    public var tools: ToolPaths
    public init(apiKey: String, hotwordTable: String? = nil, tools: ToolPaths = ToolPaths()) {
        self.apiKey = apiKey
        self.hotwordTable = hotwordTable
        self.tools = tools
    }
    public func transcribe(
        input: URL, duration: Double, cancellation: CancellationToken, progress: @escaping (Double) -> Void
    ) throws -> Transcript {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("chuangcut-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: audio) }
        try FFmpegRunner(tools: tools).extractSpeech(input, to: audio, cancellation: cancellation)
        var options: [String: Any] = [
            "model_name": "bigmodel", "enable_itn": true, "enable_punc": true, "show_utterances": true,
        ]
        if let hotwordTable, !hotwordTable.isEmpty { options["corpus"] = ["boosting_table_id": hotwordTable] }
        let body: [String: Any] = [
            "user": ["uid": "chuangcut"], "audio": ["data": try Data(contentsOf: audio).base64EncodedString()],
            "request": options,
        ]
        // The flash endpoint answers in one response: about 4 s for 5 minutes and 12 s for 30 minutes of audio.
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120 + duration / 5)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (field, value) in [
            "Content-Type": "application/json", "X-Api-Key": apiKey, "X-Api-Resource-Id": Self.resource,
            "X-Api-Request-Id": UUID().uuidString, "X-Api-Sequence": "-1",
        ] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let expected = 3 + duration * 0.008
        let (data, response) = try Self.send(request, cancellation: cancellation) {
            progress(min(0.95, $0 / expected))
        }
        let status = response.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        let message = response.value(forHTTPHeaderField: "X-Api-Message") ?? ""
        switch status {
        case "20000000": break
        case "20000003": return Transcript(segments: [])  // Silent audio.
        case _ where response.statusCode == 401 || response.statusCode == 403 || status.hasPrefix("4500003"):
            throw ChuangCutError.message(
                "Doubao rejected the API key or the Seed-ASR resource isn't enabled: \(message)")
        default:
            throw ChuangCutError.message(
                "Doubao transcription failed (\(status.isEmpty ? "HTTP \(response.statusCode)" : status)): \(message)")
        }
        progress(1)
        return try Self.parse(data)
    }

    private final class Reply: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }
    private static func send(
        _ request: URLRequest, cancellation: CancellationToken, tick: (Double) -> Void
    ) throws -> (Data, HTTPURLResponse) {
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            reply.data = data
            reply.response = response
            reply.error = error
            done.signal()
        }
        task.resume()
        let started = Date()
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if cancellation.isCancelled { task.cancel() }
            tick(Date().timeIntervalSince(started))
        }
        try cancellation.check()
        if let error = reply.error {
            throw ChuangCutError.message("Doubao transcription failed: \(error.localizedDescription)")
        }
        guard let response = reply.response as? HTTPURLResponse else {
            throw ChuangCutError.message("Doubao transcription failed: no response")
        }
        return (reply.data ?? Data(), response)
    }

    /// Accepts the full flash response or its `result` object. Each utterance becomes a segment; characters keep
    /// their own timestamps and the utterance's punctuation is interleaved as zero-length words.
    public static func parse(_ data: Data) throws -> Transcript {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChuangCutError.message("Invalid Doubao JSON")
        }
        let result = root["result"] as? [String: Any] ?? root
        func seconds(_ value: Any?) -> Double { ((value as? NSNumber)?.doubleValue ?? -1) / 1000 }
        var segments: [Segment] = []
        for utterance in result["utterances"] as? [[String: Any]] ?? [] {
            let text = utterance["text"] as? String ?? ""
            let start = max(0, seconds(utterance["start_time"]))
            let end = max(start, seconds(utterance["end_time"]))
            var words: [Word] = []
            var cursor = text.startIndex
            var last = start
            func punctuation(_ gap: Substring) {
                let marks = gap.filter { !$0.isWhitespace }
                if !marks.isEmpty { words.append(Word(text: String(marks), start: last, end: last)) }
            }
            for item in utterance["words"] as? [[String: Any]] ?? [] {
                let piece = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !piece.isEmpty else { continue }
                let from = seconds(item["start_time"])
                let wordStart = from >= 0 ? from : last
                let wordEnd = max(wordStart, seconds(item["end_time"]))
                var spaced = false
                if let match = text.range(of: piece, range: cursor..<text.endIndex) {
                    punctuation(text[cursor..<match.lowerBound])
                    spaced = text[cursor..<match.lowerBound].contains(where: \.isWhitespace)
                    cursor = match.upperBound
                }
                // Latin words keep the space that separates them, as Whisper's tokens do.
                let latin = !piece.contains(where: isCJK) && !words.isEmpty
                words.append(Word(text: (latin && spaced ? " " : "") + piece, start: wordStart, end: wordEnd))
                last = wordEnd
            }
            punctuation(text[cursor...])
            if words.isEmpty && !text.isEmpty { words = [Word(text: text, start: start, end: end)] }
            segments.append(Segment(start: start, end: end, text: text, words: words))
        }
        return Transcript(segments: segments, language: "zh")
    }
}
