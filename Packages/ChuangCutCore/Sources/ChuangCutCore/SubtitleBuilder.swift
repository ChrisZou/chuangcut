import Foundation
import NaturalLanguage

public struct SubtitleCue: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
public struct SubtitleBuilder {
    public var style: SubtitleStyle
    public init(style: SubtitleStyle = SubtitleStyle()) { self.style = style }
    private let ending = CharacterSet(charactersIn: "。，！？、,.!?，；;：: ")
    /// Whisper segments are sentence-like even when Whisper emits no sentence-final punctuation, so
    /// each segment end also ends a subtitle sentence.
    public func build(
        transcript: Transcript?, mapper: TimelineMapper, fillers: [CutCandidate] = [], maxCues: Int = .max
    ) -> [SubtitleCue] {
        build(
            words: transcript?.words ?? [], mapper: mapper, fillers: fillers, maxCues: maxCues,
            sentenceEnds: transcript?.sentenceEnds ?? [])
    }
    /// `maxCues` stops early when a caller such as a style preview needs only the first cues.
    public func build(
        words: [Word], mapper: TimelineMapper, fillers: [CutCandidate] = [], maxCues: Int = .max,
        sentenceEnds: Set<UUID> = []
    ) -> [SubtitleCue] {
        let fillerMapper = TimelineMapper(duration: mapper.duration, cuts: fillers.filter { $0.kind == .filler })
        var cues: [SubtitleCue] = []
        var buffer: [Word] = []
        func flush(_ chunk: [Word]) {
            guard let first = chunk.first, let last = chunk.last else { return }
            var text = TextNormalization.cjkPunctuation(chunk.map(\.text).joined()).trimmingCharacters(
                in: .whitespacesAndNewlines)
            while let last = text.unicodeScalars.last, ending.contains(last) { text.removeLast() }
            if style.replaceInnerPunctuationWithSpaces && TextNormalization.isCJKDominant(text) {
                text = text.replacingOccurrences(of: "[，、；：\\s]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !text.isEmpty else { return }
            let start = max(cues.last?.end ?? 0, mapper.sourceToCut(first.start))
            let end = min(mapper.editedDuration, max(start + 0.04, mapper.sourceToCut(last.end)))
            if end > start { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        func splitSentence(_ sentence: [Word]) {
            guard !sentence.isEmpty, cues.count < maxCues else { return }
            let text = sentence.map(\.text).joined()
            let cjk = TextNormalization.isCJKDominant(text)
            let limit = cjk ? max(8, style.cjkLineLength) : max(8, style.latinLineLength)
            let length = text.trimmingCharacters(in: ending).count
            let duration = mapper.sourceToCut(sentence.last!.end) - mapper.sourceToCut(sentence.first!.start)
            guard sentence.count > 1, length > limit || duration > 5.5 else {
                flush(sentence)
                return
            }
            let totalCJK = text.filter(isCJK).count
            let connectives: Set<String> = ["然后", "但是", "所以", "因为", "而且", "接着", "最后", "首先", "其实", "那么"]
            let clauseMarks = CharacterSet(charactersIn: "，、；：,;:")
            // Per-scalar prefix tables replace re-joining both halves for every breakpoint, which
            // was quadratic for long unpunctuated sentences. Clause marks are a subset of `ending`.
            let scalars = Array(text.unicodeScalars)
            var cjkBefore = [0]
            var afterLastMark = [0]
            var afterLastKept = [0]
            for (k, scalar) in scalars.enumerated() {
                cjkBefore.append(cjkBefore[k] + (isCJK(Character(scalar)) ? 1 : 0))
                afterLastMark.append(clauseMarks.contains(scalar) ? k + 1 : afterLastMark[k])
                afterLastKept.append(ending.contains(scalar) ? afterLastKept[k] : k + 1)
            }
            let firstKept = scalars.firstIndex { !ending.contains($0) } ?? scalars.count
            var wordEnd: [Int] = []
            for word in sentence { wordEnd.append((wordEnd.last ?? 0) + word.text.unicodeScalars.count) }
            // Whether everything from word i on is ending punctuation, and its first non-space scalar.
            var restIsEnding = Array(repeating: true, count: sentence.count + 1)
            var restFirst = [Unicode.Scalar?](repeating: nil, count: sentence.count + 1)
            for i in sentence.indices.reversed() {
                let wordScalars = sentence[i].text.unicodeScalars
                restIsEnding[i] = wordScalars.allSatisfy { ending.contains($0) } && restIsEnding[i + 1]
                restFirst[i] = wordScalars.first { !CharacterSet.whitespaces.contains($0) } ?? restFirst[i + 1]
            }
            var offset = 0
            var options: [(index: Int, offset: Int, punctuation: Bool, shortTail: Bool, score: Double)] = []
            for i in 1..<sentence.count {
                offset += sentence[i - 1].text.count
                let leftEnd = wordEnd[i - 1]
                if restIsEnding[i] { continue }
                // Keep punctuation with its clause, and a short connective with what follows.
                if let first = restFirst[i], clauseMarks.contains(first) { continue }
                // The tail is the left half's last clause once ending punctuation is trimmed.
                let trimmedEnd = afterLastKept[leftEnd]
                var tailStart = max(firstKept, afterLastMark[trimmedEnd])
                var tailEnd = max(tailStart, trimmedEnd)
                while tailStart < tailEnd, CharacterSet.whitespaces.contains(scalars[tailStart]) { tailStart += 1 }
                while tailEnd > tailStart, CharacterSet.whitespaces.contains(scalars[tailEnd - 1]) { tailEnd -= 1 }
                if cjk && tailEnd - tailStart <= 2 {
                    var tail = String.UnicodeScalarView()
                    tail.append(contentsOf: scalars[tailStart..<tailEnd])
                    if connectives.contains(String(tail)) { continue }
                }
                let tailCount = cjkBefore[tailEnd] - cjkBefore[tailStart]
                let shortTail = cjk && tailCount > 0 && tailCount <= 3 && afterLastMark[leftEnd] > 0
                // A short complete sentence may stand alone, but splitting must not create an orphan.
                let leftCJK = cjkBefore[leftEnd]
                if cjk && (leftCJK < 4 || totalCJK - leftCJK < 4) { continue }
                let punctuation = sentence[i - 1].text.contains { "，、；：,;:".contains($0) }
                let balance =
                    cjk
                    ? abs(Double(leftCJK) - Double(totalCJK) / 2)
                    : abs(Double(offset) - Double(length) / 2)
                options.append((i, offset, punctuation, shortTail, balance))
            }
            // Prefer a complete clause over balance when a breakpoint would strand a short tail.
            let preferred = options.contains { !$0.shortTail } ? options.filter { !$0.shortTail } : options
            var pool = preferred.filter(\.punctuation)
            if pool.isEmpty {
                // Word segmentation is the expensive step, so it only runs without a clause mark.
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.string = text
                var lexical: Set<Int> = []
                tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                    lexical.insert(text.distance(from: text.startIndex, to: range.upperBound))
                    return true
                }
                pool = preferred.filter { lexical.contains($0.offset) }
                if pool.isEmpty { pool = preferred }
            }
            // On an equal balance, keep the longer first half: a verb stays with its subject.
            guard let best = pool.min(by: { $0.score == $1.score ? $0.index > $1.index : $0.score < $1.score }) else {
                flush(sentence)
                return
            }
            splitSentence(Array(sentence.prefix(best.index)))
            splitSentence(Array(sentence.dropFirst(best.index)))
        }
        for word in words {
            if cues.count >= maxCues { break }
            let endsSentence = word.text.contains(where: { "。！？.!?".contains($0) }) || sentenceEnds.contains(word.id)
            if mapper.removes(word) || fillerMapper.removes(word) {
                // A cut sentence ending still separates the retained text from the next
                // sentence; deleting its punctuation must not glue the two clauses together.
                if endsSentence {
                    splitSentence(buffer)
                    buffer = []
                }
                continue
            }
            // A long pause ends a cue even after the pause itself is cut from the edit.
            if let last = buffer.last,
                mapper.sourceToCut(word.start) - mapper.sourceToCut(last.end) > 0.8 || word.start - last.end > 0.8
            {
                splitSentence(buffer)
                buffer = []
            }
            buffer.append(word)
            if endsSentence {
                splitSentence(buffer)
                buffer = []
            }
        }
        if cues.count < maxCues { splitSentence(buffer) }
        return Array(cues.prefix(maxCues))
    }
    public func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map {
            "\($0.offset + 1)\n\(Self.timestamp($0.element.start)) --> \(Self.timestamp($0.element.end))\n\($0.element.text)\n"
        }.joined(separator: "\n")
    }
    public func ass(_ cues: [SubtitleCue], width: Int, height: Int) -> String {
        let style = style.scaled(width: Double(width), height: Double(height))
        let hex = style.colorHex.replacingOccurrences(of: "#", with: "")
        let color =
            hex.count == 6
            ? String(hex.suffix(2)) + String(hex.dropFirst(2).prefix(2)) + String(hex.prefix(2)) : "FFFFFF"
        let font = style.fontName.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "\n", with: " ")
        var result = """
            [Script Info]
            ScriptType: v4.00+
            PlayResX: \(width)
            PlayResY: \(height)
            WrapStyle: 0
            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,\(font),\(style.fontSize),&H00\(color),&H00FFFFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,\(style.outline),0,2,30,30,\(Int(style.bottomMargin)),1
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

            """
        for cue in cues {
            let text = cue.text.replacingOccurrences(of: "\\", with: "＼").replacingOccurrences(of: "{", with: "（")
                .replacingOccurrences(of: "}", with: "）").replacingOccurrences(of: "\n", with: "\\N")
            result +=
                "Dialogue: 0,\(Self.timestamp(cue.start, ass: true)),\(Self.timestamp(cue.end, ass: true)),Default,,0,0,0,,\(text)\n"
        }
        return result
    }
    public static func timestamp(_ seconds: Double, ass: Bool = false) -> String {
        let scale = ass ? 100 : 1000
        let ticks = Int((max(0, seconds) * Double(scale)).rounded())
        let hours = ticks / (3600 * scale)
        let minutes = ticks / (60 * scale) % 60
        let secs = ticks / scale % 60
        let fraction = ticks % scale
        return ass
            ? String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, fraction)
            : String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, fraction)
    }
}
