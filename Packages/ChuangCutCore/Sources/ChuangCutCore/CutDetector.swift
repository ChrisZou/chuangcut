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
        for (index, word) in words.enumerated() {
            if let last = current.last, word.start - last.end > settings.pauseThreshold,
                !Self.pauseSplitsWord(current, words[index...])
            {
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
        candidates += earlierTakes(meaningful)
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
        // when Whisper ends a segment slightly before the actual audio stops, but never reaches a kept
        // word lying between the cut and the pause.
        let spoken = words.filter { !$0.isPunctuation && $0.end > $0.start }
        for i in candidates.indices where candidates[i].kind == .retake || candidates[i].kind == .filler {
            let cut = candidates[i]
            let previousEnd = spoken.last { $0.end <= cut.sourceStart + 0.001 }?.end ?? 0
            let nextStart = spoken.first { $0.start >= cut.sourceEnd - 0.001 }?.start ?? duration
            for gap in silences where gap.duration >= settings.pauseThreshold {
                if abs(gap.end - cut.sourceStart) <= 0.25 {
                    candidates[i].sourceStart = max(
                        0, min(candidates[i].sourceStart, max(gap.end - settings.padding, previousEnd)))
                }
                if abs(gap.start - cut.sourceEnd) <= 0.25 {
                    candidates[i].sourceEnd = min(
                        duration, max(candidates[i].sourceEnd, min(gap.start + settings.padding, nextStart)))
                }
            }
        }
        return candidates.filter { $0.sourceEnd > $0.sourceStart }.sorted { $0.sourceStart < $1.sourceStart }
    }
    /// How far after a phrase a repeat still counts as a retake of it.
    static let retakeWindow = 45.0
    /// Only the last take of an expression is kept. A run of up to four clauses is an earlier take when
    /// a later clause in the window starts with it again, possibly longer or slightly reworded, or, for
    /// eight or more characters, when it is said again anywhere in the window. Runs matter because a
    /// pause can split one phrase into clauses that only match a later take together.
    private func earlierTakes(_ clauses: [[Word]]) -> [CutCandidate] {
        var text: [Unicode.Scalar] = []
        var offsets: [Int] = []
        for clause in clauses {
            offsets.append(text.count)
            text += normalized(clause.map(\.text).joined()).unicodeScalars
        }
        offsets.append(text.count)
        var result: [CutCandidate] = []
        var cut = Set<Int>()
        // Short fragments (所以, 我把) wait until it is known whether the next clause is cut too.
        var fragments: [(first: Int, last: Int, later: Int)] = []
        func emit(_ first: Int, _ last: Int, later: Int) {
            let words = clauses[first...last].flatMap { $0 }
            // Whisper can collapse a take's last words onto one instant at its end; keep them inside.
            let end = words.last!.end + (words.last!.end > words.last!.start ? 0 : 0.02)
            result.append(
                CutCandidate(
                    kind: .retake, start: words.first!.start, end: end, text: words.map(\.text).joined(),
                    reason: String(format: "Earlier take; matching later phrase at %.2fs", clauses[later].first!.start))
            )
            cut.formUnion(first...last)
        }
        var i = 0
        while i < clauses.count {
            var matched = 1
            for size in stride(from: min(4, clauses.count - i), through: 1, by: -1) {
                let last = i + size - 1
                let a = Array(text[offsets[i]..<offsets[last + 1]])
                guard a.count >= 2, a.count <= 40 else { continue }
                let end = clauses[last].last!.end
                var windowEnd = last + 1
                while windowEnd < clauses.count, clauses[windowEnd].first!.start - end <= Self.retakeWindow {
                    windowEnd += 1
                }
                guard let later = laterTake(of: a, after: last, until: windowEnd, clauses, text, offsets) else {
                    continue
                }
                if a.count <= 3 {
                    fragments.append((i, last, later))
                } else {
                    emit(i, last, later: later)
                }
                matched = size
                break
            }
            i += matched
        }
        // A fragment is an abandoned start only when it is restarted at once or the speaker went on to
        // another earlier take; 所以 before kept content is ordinary speech.
        for fragment in fragments.reversed()
        where fragment.later == fragment.last + 1 || cut.contains(fragment.last + 1) {
            emit(fragment.first, fragment.last, later: fragment.later)
        }
        return result
    }
    /// The clause where `a` is said again, searching the clauses after `last` up to `windowEnd`.
    private func laterTake(
        of a: [Unicode.Scalar], after last: Int, until windowEnd: Int, _ clauses: [[Word]], _ text: [Unicode.Scalar],
        _ offsets: [Int]
    ) -> Int? {
        let threshold = a.count >= 12 ? 0.75 : 0.8
        let end = clauses[last].last!.end
        func accepted(_ match: ArraySlice<Unicode.Scalar>) -> Bool {
            // Parallel list items differ only in their ordinal.
            !Self.isEnumeration(String(String.UnicodeScalarView(a)), String(String.UnicodeScalarView(match)))
        }
        for clause in (last + 1)..<max(last + 1, windowEnd) {
            let start = offsets[clause]
            let prefix = text[start..<min(offsets[windowEnd], start + a.count + a.count / 2 + 1)]
            if a.count <= 3 {
                // A short fragment (所以, 我把) only counts when it is restarted almost at once.
                guard clause - last <= 3, clauses[clause].first!.start - end <= 10 else { break }
                if prefix.starts(with: a), accepted(prefix.prefix(a.count)) { return clause }
            } else if Self.coverage(a, in: Array(prefix), anchored: true).score >= threshold,
                accepted(prefix.prefix(a.count))
            {
                return clause
            }
        }
        guard a.count >= 8, windowEnd > last + 1 else { return nil }
        let stream = Array(text[offsets[last + 1]..<offsets[windowEnd]])
        let match = Self.coverage(a, in: stream, anchored: false)
        let start = offsets[last + 1] + match.start
        guard match.score >= threshold, accepted(text[start..<min(text.count, start + a.count)]) else { return nil }
        return ((last + 1)..<windowEnd).last { offsets[$0] <= start }
    }
    /// 1 minus the edit distance between `a` and its closest substring of `b` (a prefix of `b` when
    /// `anchored`), relative to `a`'s length, and where that substring starts in `b`.
    static func coverage(_ a: [Unicode.Scalar], in b: [Unicode.Scalar], anchored: Bool) -> (score: Double, start: Int) {
        guard !a.isEmpty, !b.isEmpty else { return (0, 0) }
        var previous = anchored ? Array(0...b.count) : Array(repeating: 0, count: b.count + 1)
        var starts = anchored ? Array(repeating: 0, count: b.count + 1) : Array(0...b.count)
        var row = previous
        var rowStarts = starts
        for (i, x) in a.enumerated() {
            row[0] = i + 1
            rowStarts[0] = starts[0]
            for (j, y) in b.enumerated() {
                let replace = previous[j] + (x == y ? 0 : 1)
                let skipA = previous[j + 1] + 1
                let skipB = row[j] + 1
                if replace <= skipA && replace <= skipB {
                    (row[j + 1], rowStarts[j + 1]) = (replace, starts[j])
                } else if skipA <= skipB {
                    (row[j + 1], rowStarts[j + 1]) = (skipA, starts[j + 1])
                } else {
                    (row[j + 1], rowStarts[j + 1]) = (skipB, rowStarts[j])
                }
            }
            swap(&previous, &row)
            swap(&starts, &rowStarts)
        }
        let best = previous.indices.min { previous[$0] < previous[$1] }!
        return (1 - Double(previous[best]) / Double(a.count), starts[best])
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
    /// Whether a pause between `before` and `after` falls inside a word. Whisper sometimes places the
    /// first character of a word (里|面) before the pause the speaker made ahead of it.
    static func pauseSplitsWord(_ before: [Word], _ after: ArraySlice<Word>) -> Bool {
        let left = before.suffix(4).map(\.text).joined()
        let right = after.prefix(4).map(\.text).joined()
        guard let last = left.last, let first = right.first, isCJK(last), isCJK(first) else { return false }
        let text = left + right
        let boundary = text.index(text.startIndex, offsetBy: left.count)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokenRange(at: boundary).lowerBound < boundary
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
