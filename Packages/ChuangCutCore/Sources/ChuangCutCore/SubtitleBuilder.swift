import Foundation
import NaturalLanguage

public struct SubtitleCue: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}
public struct SubtitleBuilder {
    public var style: SubtitleStyle
    public init(style: SubtitleStyle = SubtitleStyle()) { self.style = style }
    private let ending = CharacterSet(charactersIn: "。，！？、,.!?，；;：: ")
    public func build(words: [Word], mapper: TimelineMapper, fillers: [CutCandidate] = []) -> [SubtitleCue] {
        let fillerRanges = fillers.filter { $0.kind == .filler && $0.enabled }.map(\.range)
        var cues: [SubtitleCue] = []; var buffer: [Word] = []
        func flush(_ chunk: [Word]) {
            guard let first = chunk.first, let last = chunk.last else { return }
            var text = TextNormalization.cjkPunctuation(chunk.map(\.text).joined()).trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = text.unicodeScalars.last, ending.contains(last) { text.removeLast() }
            if style.replaceInnerPunctuationWithSpaces && TextNormalization.isCJKDominant(text) {
                text = text.replacingOccurrences(of: "[，、；：\\s]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            }
            guard !text.isEmpty else { return }
            let start = max(cues.last?.end ?? 0, mapper.sourceToCut(first.start))
            let end = min(mapper.editedDuration, max(start + 0.04, mapper.sourceToCut(last.end)))
            if end > start { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        func splitSentence(_ sentence: [Word]) {
            guard !sentence.isEmpty else { return }
            let text = sentence.map(\.text).joined()
            let cjk = TextNormalization.isCJKDominant(text)
            let limit = cjk ? max(8, style.cjkLineLength) : max(8, style.latinLineLength)
            let length = text.trimmingCharacters(in: ending).count
            let duration = mapper.sourceToCut(sentence.last!.end) - mapper.sourceToCut(sentence.first!.start)
            guard sentence.count > 1, length > limit || duration > 5.5 else { flush(sentence); return }
            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
            var lexical: Set<Int> = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                lexical.insert(text.distance(from: text.startIndex, to: range.upperBound)); return true
            }
            let totalCJK = text.filter(isCJK).count
            let connectives: Set<String> = ["然后", "但是", "所以", "因为", "而且", "接着", "最后", "首先", "其实", "那么"]
            let clauseMarks = CharacterSet(charactersIn: "，、；：,;:")
            var offset = 0, options: [(index: Int, punctuation: Bool, lexical: Bool, shortTail: Bool, score: Double)] = []
            for i in 1..<sentence.count {
                offset += sentence[i - 1].text.count
                let left = sentence.prefix(i).map(\.text).joined()
                let right = sentence.dropFirst(i).map(\.text).joined()
                if right.trimmingCharacters(in: ending).isEmpty { continue }
                // Keep punctuation with its clause, and a short connective with what follows.
                if let first = right.trimmingCharacters(in: .whitespaces).unicodeScalars.first, clauseMarks.contains(first) { continue }
                let tail = left.trimmingCharacters(in: ending).components(separatedBy: clauseMarks).last?.trimmingCharacters(in: .whitespaces) ?? ""
                if cjk && connectives.contains(tail) { continue }
                let tailCount = tail.filter(isCJK).count
                let shortTail = cjk && tailCount > 0 && tailCount <= 3 && left.contains { "，、；：,;:".contains($0) }
                // A short complete sentence may stand alone, but splitting must not create an orphan.
                if cjk && (left.filter(isCJK).count < 4 || right.filter(isCJK).count < 4) { continue }
                let punctuation = sentence[i - 1].text.contains { "，、；：,;:".contains($0) }
                let balance = cjk ? abs(Double(left.filter(isCJK).count) - Double(totalCJK) / 2) : abs(Double(offset) - Double(length) / 2)
                options.append((i, punctuation, lexical.contains(offset), shortTail, balance))
            }
            // Prefer a complete clause over balance when a breakpoint would strand a short tail.
            let preferred = options.contains { !$0.shortTail } ? options.filter { !$0.shortTail } : options
            let pool = preferred.filter(\.punctuation).isEmpty ? (preferred.filter(\.lexical).isEmpty ? preferred : preferred.filter(\.lexical)) : preferred.filter(\.punctuation)
            // On an equal balance, keep the longer first half: a verb stays with its subject.
            guard let best = pool.min(by: { $0.score == $1.score ? $0.index > $1.index : $0.score < $1.score }) else { flush(sentence); return }
            splitSentence(Array(sentence.prefix(best.index)))
            splitSentence(Array(sentence.dropFirst(best.index)))
        }
        for word in words {
            if mapper.removes(word) || TimelineMapper.removes(word, in: fillerRanges) {
                // A cut sentence ending still separates the retained text from the next
                // sentence; deleting its punctuation must not glue the two clauses together.
                if word.text.contains(where: { "。！？.!?".contains($0) }) { splitSentence(buffer); buffer = [] }
                continue
            }
            if let last = buffer.last, mapper.sourceToCut(word.start) - mapper.sourceToCut(last.end) > 0.8 { splitSentence(buffer); buffer = [] }
            buffer.append(word)
            if word.text.contains(where: { "。！？.!?".contains($0) }) { splitSentence(buffer); buffer = [] }
        }
        splitSentence(buffer)
        return cues
    }
    public func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { "\($0.offset + 1)\n\(Self.timestamp($0.element.start)) --> \(Self.timestamp($0.element.end))\n\($0.element.text)\n" }.joined(separator: "\n")
    }
    public func ass(_ cues: [SubtitleCue], width: Int, height: Int) -> String {
        let hex = style.colorHex.replacingOccurrences(of: "#", with: "")
        let color = hex.count == 6 ? String(hex.suffix(2)) + String(hex.dropFirst(2).prefix(2)) + String(hex.prefix(2)) : "FFFFFF"
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
            let text = cue.text.replacingOccurrences(of: "\\", with: "＼").replacingOccurrences(of: "{", with: "（").replacingOccurrences(of: "}", with: "）").replacingOccurrences(of: "\n", with: "\\N")
            result += "Dialogue: 0,\(Self.timestamp(cue.start, ass: true)),\(Self.timestamp(cue.end, ass: true)),Default,,0,0,0,,\(text)\n"
        }
        return result
    }
    public static func timestamp(_ seconds: Double, ass: Bool = false) -> String {
        let scale = ass ? 100 : 1000
        let ticks = Int((max(0, seconds) * Double(scale)).rounded())
        let hours = ticks / (3600 * scale), minutes = ticks / (60 * scale) % 60, secs = ticks / scale % 60, fraction = ticks % scale
        return ass ? String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, fraction) : String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, fraction)
    }
}
