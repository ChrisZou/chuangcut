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
        let kept = words.filter { word in
            !mapper.removes(word) && !fillers.contains { $0.kind == .filler && $0.range.contains((word.start + word.end) / 2) }
        }
        var cues: [SubtitleCue] = []; var buffer: [Word] = []
        func flush(_ chunk: [Word]) {
            guard let first = chunk.first, let last = chunk.last else { return }
            let text = chunk.map(\.text).joined().trimmingCharacters(in: ending.union(.whitespacesAndNewlines))
            guard !text.isEmpty else { return }
            let start = max(cues.last?.end ?? 0, mapper.sourceToCut(first.start))
            let end = min(mapper.editedDuration, max(start + 0.04, mapper.sourceToCut(last.end)))
            if end > start { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        func splitSentence(_ sentence: [Word]) {
            var rest = sentence
            while !rest.isEmpty {
                let text = rest.map(\.text).joined()
                let cjk = text.contains(where: isCJK)
                let limit = cjk ? max(2, style.cjkLineLength) : max(8, style.latinLineLength)
                var count = 0, length = 0
                for word in rest {
                    let nextLength = length + word.text.count
                    let span = mapper.sourceToCut(word.end) - mapper.sourceToCut(rest[0].start)
                    if count > 0 && (nextLength > limit || span > 5.5) { break }
                    count += 1; length = nextLength
                }
                count = max(1, count)
                if count < rest.count {
                    let preferred = (0..<count).last { index in
                        rest[index].text.contains { "，、；：,;:".contains($0) } && index >= count / 3
                    }
                    if let preferred { count = preferred + 1 }
                    else {
                        // Balance a short final CJK tail instead of flashing one or two characters.
                        let tailLength = rest.dropFirst(count).map(\.text).joined().trimmingCharacters(in: ending).count
                        if cjk && tailLength > 0 && tailLength < max(3, limit / 3) {
                            let target = (text.trimmingCharacters(in: ending).count + 1) / 2
                            let maximum = count
                            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
                            var boundaries: Set<Int> = []
                            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                                boundaries.insert(text.distance(from: text.startIndex, to: range.upperBound)); return true
                            }
                            var accumulated = 0, choices: [(Int, Int)] = []
                            for index in 0..<maximum {
                                accumulated += rest[index].text.count
                                if boundaries.contains(accumulated) { choices.append((index + 1, abs(accumulated - target))) }
                            }
                            if let best = choices.min(by: { $0.1 < $1.1 }) { count = best.0 }
                        }
                    }
                }
                flush(Array(rest.prefix(count))); rest.removeFirst(count)
                while let first = rest.first, first.isPunctuation { rest.removeFirst() }
            }
        }
        for word in kept {
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
