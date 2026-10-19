import Foundation

public enum TextNormalization {
    public static func isCJKDominant(_ text: String) -> Bool {
        let cjk = text.filter(isCJK).count
        let other = text.filter { !isCJK($0) && $0.isLetter }.count
        return cjk > 0 && cjk >= other
    }
    public static func cjkPunctuation(_ text: String, dominant: Bool? = nil) -> String {
        guard dominant ?? isCJKDominant(text) else { return text }
        let map: [Character: Character] = [",": "，", "?": "？", "!": "！", ":": "：", ";": "；"]
        return String(text.map { map[$0] ?? $0 })
    }
}
extension Transcript {
    public mutating func normalizePunctuation() {
        for i in segments.indices {
            let dominant = TextNormalization.isCJKDominant(segments[i].text)
            segments[i].text = TextNormalization.cjkPunctuation(segments[i].text, dominant: dominant)
            for j in segments[i].words.indices {
                segments[i].words[j].text = TextNormalization.cjkPunctuation(
                    segments[i].words[j].text, dominant: dominant)
            }
        }
    }
}
