import Foundation
import NaturalLanguage

public struct CutDetector {
    public var settings: DetectionSettings
    public init(settings: DetectionSettings = DetectionSettings()) { self.settings = settings }
    private let delimiters = CharacterSet(charactersIn: "，。！？,.!?；;：:、\n")
    private static let punctuationOrSpace = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
    private func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { !Self.punctuationOrSpace.contains($0) }.map(String.init).joined()
    }
    public func clauses(_ words: [Word], sentenceEnds: Set<UUID> = []) -> [[Word]] {
        var result: [[Word]] = []
        var current: [Word] = []
        for word in words {
            if let last = current.last, word.start - last.end > settings.pauseThreshold {
                result.append(current)
                current = []
            }
            current.append(word)
            if word.text.unicodeScalars.contains(where: { delimiters.contains($0) }) || sentenceEnds.contains(word.id) {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { $0.contains { !$0.isPunctuation } }
    }
    /// `sentenceEnds` holds the last word of each Whisper segment; segments are sentence-like even
    /// when Whisper emits no sentence-final punctuation.
    public func detect(
        words: [Word], duration: Double, silences: [TimeRange] = [], sentenceEnds: Set<UUID> = []
    ) -> [CutCandidate] {
        guard !words.isEmpty else { return [] }
        var candidates: [CutCandidate] = []
        // When available, acoustic silence is authoritative: ASR often leaves false gaps inside speech.
        var gaps = silences
        if silences.isEmpty {
            let spoken = words.filter { !$0.isPunctuation }
            var cursor = 0.0
            for word in spoken {
                if word.start - cursor > settings.pauseThreshold { gaps.append(TimeRange(cursor, word.start)) }
                cursor = max(cursor, word.end)
            }
            if duration - cursor > settings.pauseThreshold { gaps.append(TimeRange(cursor, duration)) }
        }
        for gap in TimelineMapper.merge(gaps) where gap.duration >= settings.pauseThreshold {
            let start = max(0, gap.start + settings.padding)
            let end = min(duration, gap.end - settings.padding)
            if end > start {
                candidates.append(
                    CutCandidate(
                        kind: .pause, start: start, end: end, text: String(format: "⏸ %.1fs", gap.duration),
                        reason: "Silence longer than threshold"))
            }
        }
        let allClauses = clauses(words, sentenceEnds: sentenceEnds)
        let fillers = Set(settings.fillers.map(normalized))
        var meaningful: [[Word]] = []
        var sentence: [(words: [Word], isFiller: Bool)] = []
        for (index, clause) in allClauses.enumerated() {
            let isFiller = isFillerClause(clause, fillers)
            if !isFiller { meaningful.append(clause) }
            sentence.append((clause, isFiller))
            if index == allClauses.count - 1 || endsSentence(clause, before: allClauses[index + 1], sentenceEnds) {
                candidates += edgeFillers(sentence, fillers: fillers, duration: duration)
                sentence = []
            }
        }
        for i in meaningful.indices {
            let earlier = meaningful[i]
            let a = normalized(earlier.map(\.text).joined())
            guard a.count >= 4 else { continue }
            for j in (i + 1)..<min(meaningful.count, i + 4) {
                let later = meaningful[j]
                guard later.first!.start - earlier.last!.end <= 10 else { break }
                let b = normalized(later.map(\.text).joined())
                if Self.similarity(a, b) >= 0.8 || (a.count >= 4 && b.hasPrefix(a)), !Self.isEnumeration(a, b) {
                    candidates.append(
                        CutCandidate(
                            kind: .retake, start: earlier.first!.start, end: earlier.last!.end,
                            text: earlier.map(\.text).joined(),
                            reason:
                                "Earlier take; matching later phrase at \(String(format: "%.2f", later.first!.start))s")
                    )
                    break
                }
            }
        }
        // Adjacent short phrase repetitions, including CJK character words and Latin words.
        for clause in meaningful {
            let spoken = clause.filter { !$0.isPunctuation }
            let spokenText = spoken.map(\.text).joined()
            var i = 0
            while i < spoken.count {
                var matched = false
                for size in stride(from: min(4, (spoken.count - i) / 2), through: 1, by: -1) where size > 0 {
                    let first = Array(spoken[i..<(i + size)])
                    let second = Array(spoken[(i + size)..<(i + size * 2)])
                    if normalized(first.map(\.text).joined()) == normalized(second.map(\.text).joined()),
                        second.first!.start - first.last!.end < 0.5
                    {
                        let text = first.map(\.text).joined()
                        // A single repeated CJK character is often a legitimate reduplication (看看, 人人).
                        if size == 1 && text.count == 1 && text.first.map(isCJK) == true { continue }
                        let offset = spoken[..<i].reduce(0) { $0 + $1.text.count }
                        if Self.isReduplication(text, in: spokenText, at: offset) { continue }
                        candidates.append(
                            CutCandidate(
                                kind: .retake, start: first.first!.start, end: first.last!.end, text: text,
                                reason: "Immediate repeated phrase"))
                        i += size
                        matched = true
                        break
                    }
                }
                if !matched { i += 1 }
            }
        }
        // Join speech cuts to nearby acoustic pause cuts. This removes residual final phonemes
        // when Whisper ends a segment slightly before the actual audio stops.
        for i in candidates.indices where candidates[i].kind == .retake || candidates[i].kind == .filler {
            for gap in silences where gap.duration >= settings.pauseThreshold {
                if abs(gap.end - candidates[i].sourceStart) <= 0.25 {
                    candidates[i].sourceStart = max(0, min(candidates[i].sourceStart, gap.end - settings.padding))
                }
                if abs(gap.start - candidates[i].sourceEnd) <= 0.25 {
                    candidates[i].sourceEnd = min(duration, max(candidates[i].sourceEnd, gap.start + settings.padding))
                }
            }
        }
        return candidates.filter { $0.sourceEnd > $0.sourceStart }.sorted { $0.sourceStart < $1.sourceStart }
    }
    /// Whole-clause matching protects e.g. “那个视频” and “这个软件”.
    private func isFillerClause(_ clause: [Word], _ fillers: Set<String>) -> Bool {
        let norm = normalized(clause.map(\.text).joined())
        return fillers.contains(norm)
            || fillers.contains { filler in
                !filler.isEmpty && norm.count >= filler.count * 2
                    && norm.replacingOccurrences(of: filler, with: "").isEmpty
            }
    }
    /// A sentence ends at 。！？, at the end of a Whisper segment, or at a pause long enough to be cut.
    private func endsSentence(_ clause: [Word], before next: [Word], _ sentenceEnds: Set<UUID>) -> Bool {
        guard let last = clause.last, let following = next.first(where: { !$0.isPunctuation }) else { return true }
        if sentenceEnds.contains(last.id) || last.text.contains(where: { "。！？.!?".contains($0) }) { return true }
        let end = clause.last(where: { !$0.isPunctuation })?.end ?? last.end
        return following.start - end >= settings.pauseThreshold
    }
    private static let hesitations: Set<String> = ["嗯", "呃", "额", "um", "uh", "er"]
    /// Cuts the fillers that open or close a sentence: whole filler clauses (“嗯，” “那个那个，”) and
    /// hesitation tokens, which can occur without punctuation. Fillers between two pieces of content
    /// are kept, because cutting inside continuous speech breaks its rhythm.
    private func edgeFillers(
        _ sentence: [(words: [Word], isFiller: Bool)], fillers: Set<String>, duration: Double
    ) -> [CutCandidate] {
        // One entry per filler clause or spoken word; nil marks content.
        var units: [CutCandidate?] = []
        for clause in sentence {
            let text = clause.words.map(\.text).joined()
            if clause.isFiller {
                let start = clause.words.first!.start
                let end = max(start + 0.02, clause.words.map(\.end).max()!)
                units.append(
                    CutCandidate(
                        kind: .filler, start: max(0, start - 0.015), end: min(duration, end + 0.015), text: text,
                        reason: ""))
                continue
            }
            var offset = 0
            for word in clause.words {
                defer { offset += word.text.count }
                if word.isPunctuation { continue }
                let token = normalized(word.text)
                // 额 is also part of ordinary words (额度, 金额, 名额, 额外); only a standalone one is a filler.
                let isHesitation =
                    Self.hesitations.contains(token) && fillers.contains(token)
                    && !(token.contains(where: isCJK) && Self.wordLength(in: text, at: offset) > word.text.count)
                units.append(
                    isHesitation
                        ? CutCandidate(
                            kind: .filler, start: word.start, end: max(word.end, word.start + 0.02), text: word.text,
                            reason: "") : nil)
            }
        }
        let first = units.firstIndex { $0 == nil } ?? units.count
        let last = units.lastIndex { $0 == nil } ?? units.count
        return units.indices.compactMap { index in
            guard var cut = units[index], index < first || index > last else { return nil }
            cut.reason = index < first ? "Filler at the start of a sentence" : "Filler at the end of a sentence"
            return cut
        }
    }
    /// Length of the segmented word containing the character at `offset`.
    static func wordLength(in text: String, at offset: Int) -> Int {
        guard offset < text.count else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return text[tokenizer.tokenRange(at: text.index(text.startIndex, offsetBy: offset))].count
    }
    /// Chinese doubles words on purpose: 哈哈哈哈 (laughter), 体验体验 / 研究研究 (verb reduplication),
    /// 谢谢谢谢 (emphasis). Stutters such as 我们我们 or 这个这个 are pronouns, conjunctions or partial words.
    static func isReduplication(_ unit: String, in text: String, at offset: Int) -> Bool {
        guard unit.contains(where: isCJK), offset < text.count else { return false }
        if Set(unit).count == 1 { return true }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let (tag, range) = tagger.tag(
            at: text.index(text.startIndex, offsetBy: offset), unit: .word, scheme: .lexicalClass)
        let word = text[range]
        return word.count >= unit.count * 2 || (word == unit && tag == .verb)
    }
    private static let enumerationMarkers = ["首先", "其次", "再次", "然后", "接着", "最后", "另外", "此外"]
    /// Parallel list items (第一个…/第二个…, 首先…/其次…) differ only in their ordinal, so they read like
    /// a near-identical retake but are separate content.
    static func isEnumeration(_ lhs: String, _ rhs: String) -> Bool {
        var counts: [Character: Int] = [:]
        for character in lhs { counts[character, default: 0] += 1 }
        for character in rhs { counts[character, default: 0] -= 1 }
        // Both sides must carry their own numeral (第一 ↔ 第二); a numeral present on one side only, as in
        // 聊一聊 → 聊, is an ordinary rewording of a retake.
        let numerals = Set("0123456789零一二三四五六七八九十两百千万")
        let differing = counts.filter { $0.value != 0 && numerals.contains($0.key) }.values
        if differing.contains(where: { $0 > 0 }) && differing.contains(where: { $0 < 0 }) { return true }
        let left = enumerationMarkers.first { lhs.hasPrefix($0) }
        let right = enumerationMarkers.first { rhs.hasPrefix($0) }
        return left != nil && right != nil && left != right
    }
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                row[j + 1] = min(row[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1))
            }
            previous = row
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
