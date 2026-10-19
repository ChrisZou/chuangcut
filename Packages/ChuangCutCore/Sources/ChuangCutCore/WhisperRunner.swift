import Foundation

public struct WhisperRunner {
    public var tools: ToolPaths
    public init(tools: ToolPaths = ToolPaths()) { self.tools = tools }
    public func transcribe(
        wav: URL, model: URL, language: String, output: URL, cancellation: CancellationToken,
        progress: @escaping (Double) -> Void
    ) throws -> Transcript {
        var args = [
            "-m", model.path, "-l", language, "-ojf", "-of", output.deletingPathExtension().path, "-f", wav.path, "-pp",
        ]
        // DTW provides useful token anchors where default timestamps collapse entire clauses.
        let name = model.lastPathComponent
        let alignment: String? =
            name.contains("large-v3-turbo")
            ? "large.v3.turbo" : name.contains("medium") ? "medium" : name.contains("small") ? "small" : nil
        if let alignment { args += ["-dtw", alignment, "-nfa"] }
        _ = try ProcessRunner.run(
            tools.whisper, args, cancellation: cancellation,
            stderr: { line in
                if let range = line.range(of: #"progress\s*=\s*(\d+)%"#, options: .regularExpression) {
                    let number = line[range].filter(\.isNumber)
                    progress((Double(number) ?? 0) / 100)
                }
            })
        progress(1)
        return try Self.parse(Data(contentsOf: output), language: language)
    }
    public static func parse(_ data: Data, language: String = "zh") throws -> Transcript {
        // Decode invalid byte-token strings lossily; recover their actual characters from segment text.
        let clean = Data(String(decoding: data, as: UTF8.self).utf8)
        guard let root = try JSONSerialization.jsonObject(with: clean) as? [String: Any],
            let entries = root["transcription"] as? [[String: Any]]
        else { throw ChuangCutError.message("Invalid whisper JSON") }
        var segments: [Segment] = []
        for entry in entries {
            let offset = entry["offsets"] as? [String: Double] ?? [:]
            let start = (offset["from"] ?? 0) / 1000
            let end = (offset["to"] ?? 0) / 1000
            let text = entry["text"] as? String ?? ""
            let raw = (entry["tokens"] as? [[String: Any]] ?? []).filter {
                !(($0["text"] as? String ?? "").hasPrefix("[_"))
            }
            var recovered: [Word] = []
            var cursor = text.startIndex
            var fragmentStart: Double?
            for (index, token) in raw.enumerated() {
                let piece = token["text"] as? String ?? ""
                let offsets = token["offsets"] as? [String: Double] ?? [:]
                let from = max(start, (offsets["from"] ?? start * 1000) / 1000)
                let to = min(end, max(from, (offsets["to"] ?? end * 1000) / 1000))
                let probability = token["p"] as? Double ?? 1
                if piece.contains("�") {
                    if fragmentStart == nil { fragmentStart = from }
                    continue
                }
                guard !piece.isEmpty else { continue }
                if let match = text.range(of: piece, range: cursor..<text.endIndex) {
                    if cursor < match.lowerBound {
                        recovered.append(
                            Word(
                                text: String(text[cursor..<match.lowerBound]), start: fragmentStart ?? from, end: from,
                                confidence: probability))
                    }
                    var word = Word(text: piece, start: from, end: to, confidence: probability)
                    let anchor = token["t_dtw"] as? Double ?? -1
                    if anchor >= 0 {
                        word.start = max(start, min(end, anchor / 100))
                        word.end = word.start
                    }
                    recovered.append(word)
                    cursor = match.upperBound
                    fragmentStart = nil
                } else if index == raw.count - 1 && cursor < text.endIndex {
                    break
                }
            }
            if cursor < text.endIndex {
                recovered.append(
                    Word(text: String(text[cursor...]), start: fragmentStart ?? recovered.last?.end ?? start, end: end))
            }
            if recovered.isEmpty && !text.isEmpty { recovered = [Word(text: text, start: start, end: end)] }
            // DTW anchors are centers. Derive boundaries from neighboring centers, retaining segment limits.
            let hasDTW = raw.contains { ($0["t_dtw"] as? Double ?? -1) >= 0 }
            if hasDTW {
                let centers = recovered.map(\.start)
                for i in recovered.indices {
                    recovered[i].start = i == 0 ? start : (centers[i - 1] + centers[i]) / 2
                    recovered[i].end = i == recovered.count - 1 ? end : (centers[i] + centers[i + 1]) / 2
                }
            }
            var words: [Word] = []
            for (i, token) in recovered.enumerated() {
                let next = i + 1 < recovered.count ? recovered[i + 1].start : end
                let finish = max(
                    token.start, min(end, token.end > token.start ? token.end : max(token.start + 0.01, next)))
                if token.text.contains(where: isCJK) {
                    let chars = Array(token.text)
                    for (j, char) in chars.enumerated() {
                        let a = token.start + (finish - token.start) * Double(j) / Double(chars.count)
                        let b = token.start + (finish - token.start) * Double(j + 1) / Double(chars.count)
                        words.append(Word(text: String(char), start: a, end: b, confidence: token.confidence))
                    }
                } else if !token.isPunctuation, !token.text.hasPrefix(" "), let last = words.last, !last.isPunctuation,
                    !last.text.contains(where: isCJK)
                {
                    words[words.count - 1].text += token.text
                    words[words.count - 1].end = finish
                } else {
                    words.append(Word(text: token.text, start: token.start, end: finish, confidence: token.confidence))
                }
            }
            segments.append(Segment(start: start, end: end, text: text, words: words))
        }
        return Transcript(segments: segments, language: language)
    }
}
