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
        words: [Word], duration: Double, silences: [TimeRange] = [], sentenceEnds: Set<UUID> = [],
        loudness: Loudness? = nil
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
        // Restarts inside a clause come first, so a clause like 如果如果你正在搞 is compared with later
        // takes as 如果你正在搞.
        let restarts = restartedPhrases(meaningful)
        var restarted = Set(restarts.flatMap { $0.words.map(\.id) })
        func remaining(_ clauses: [[Word]]) -> [[Word]] {
            clauses.map { $0.filter { !restarted.contains($0.id) } }.filter { $0.contains { !$0.isPunctuation } }
        }
        let heads = strayHeads(remaining(meaningful))
        restarted.formUnion(heads.flatMap { $0.words.map(\.id) })
        candidates += (restarts + heads).map(\.cut)
        candidates += earlierTakes(remaining(meaningful))
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
        candidates = candidates.filter { $0.sourceEnd > $0.sourceStart }.sorted { $0.sourceStart < $1.sourceStart }
        fitKeptStretches(
            &candidates, spoken: spoken, gaps: pauseTargets(words, sentenceEnds: sentenceEnds), duration: duration,
            loudness: loudness)
        return candidates.filter { $0.sourceEnd > $0.sourceStart }.sorted { $0.sourceStart < $1.sourceStart }
    }
    /// Shapes each stretch left between cuts around its speech. A stretch with no kept word (a breath, a burp,
    /// the padding before the first word) is cut. With loudness, the others start `leadIn` before their first
    /// word becomes audible, so picture and voice arrive together, and end so the join sounds like the pause
    /// the last word's punctuation calls for, instead of wherever a silence or a removed take happened to stop.
    /// Pauses inside a stretch that run longer than their punctuation calls for are shortened to it, so every
    /// pause in the edit follows the same rhythm.
    private func fitKeptStretches(
        _ candidates: inout [CutCandidate], spoken: [Word], gaps: [UUID: Double], duration: Double,
        loudness: Loudness?
    ) {
        var shortened: [CutCandidate] = []
        let removed = TimelineMapper.merge(candidates.map(\.range))
        var stretches: [TimeRange] = []
        var cursor = 0.0
        for range in removed {
            if range.start > cursor { stretches.append(TimeRange(cursor, range.start)) }
            cursor = max(cursor, range.end)
        }
        if cursor < duration { stretches.append(TimeRange(cursor, duration)) }
        let mids = spoken.map { ($0.start + $0.end) / 2 }
        for stretch in stretches {
            let before = candidates.indices.filter { abs(candidates[$0].sourceEnd - stretch.start) < 1e-6 }
            let after = candidates.indices.filter { abs(candidates[$0].sourceStart - stretch.end) < 1e-6 }
            // Words are in time order, so the stretch's words are one run.
            let lower = TimelineMapper.firstIndex(count: mids.count) { mids[$0] >= stretch.start }
            let upper = TimelineMapper.firstIndex(count: mids.count) { mids[$0] >= stretch.end }
            guard lower < upper else {
                if !before.isEmpty {
                    for i in before { candidates[i].sourceEnd = stretch.end }
                } else if !after.isEmpty {
                    for i in after { candidates[i].sourceStart = stretch.start }
                }
                continue
            }
            guard let loudness else { continue }
            let (firstIndex, lastIndex) = (lower, upper - 1)
            let first = spoken[firstIndex]
            let last = spoken[lastIndex]
            if !before.isEmpty {
                // Never reach back into the removed word before the stretch, and keep the first word's
                // midpoint, which decides whether the word counts as kept.
                let lower = max(
                    firstIndex > 0 ? spoken[firstIndex - 1].end : 0, before.map { candidates[$0].sourceStart }.max()!)
                if let onset = loudness.onset(from: max(lower, first.start - 0.25), to: first.end + 0.1) {
                    let start = min(mids[firstIndex], max(lower, onset - settings.leadIn))
                    for i in before { candidates[i].sourceEnd = start }
                }
            }
            if !after.isEmpty {
                let upper = min(
                    lastIndex + 1 < spoken.count ? spoken[lastIndex + 1].start : duration,
                    after.map { candidates[$0].sourceEnd }.min()!)
                // Stop short of the next word: its timestamp can trail its first audible frame. Look back before
                // the last word too: its timestamps can trail its sound, which may have stopped before they begin.
                if let offset = loudness.offset(
                    from: max(stretch.start, last.start - 0.5), to: max(last.end, min(upper - 0.1, last.end + 0.35)))
                {
                    // The next clip brings `leadIn` of room sound of its own.
                    let tail = max(0, (gaps[last.id] ?? settings.wordGap) - settings.leadIn)
                    let end = max(mids[lastIndex], min(upper, offset + tail))
                    for i in after { candidates[i].sourceStart = end }
                }
            }
            for index in firstIndex..<lastIndex {
                let target = gaps[spoken[index].id] ?? settings.wordGap
                guard let quiet = loudness.longestQuiet(from: mids[index], to: mids[index + 1]) else { continue }
                // The next word is heard from its softer attack on, which can begin inside the quiet run.
                let heard = loudness.onset(from: quiet.start, to: min(stretch.end, quiet.end + 0.3)) ?? quiet.end
                guard heard - quiet.start > target + 0.06 else { continue }
                let cut = TimeRange(quiet.start + max(0, target - settings.leadIn), heard - settings.leadIn)
                // A word whose timestamps reach into the pause would read as removed while it is still heard.
                guard cut.end > cut.start, !mids.contains(where: { $0 >= cut.start && $0 < cut.end }) else { continue }
                shortened.append(
                    CutCandidate(
                        kind: .pause, start: cut.start, end: cut.end,
                        reason: String(format: "Pause shortened to %.2fs", target)))
            }
        }
        candidates += shortened
    }
    /// The silence to leave after each spoken word, from the punctuation that follows it: a word's own text can
    /// end in punctuation (Whisper), or punctuation can follow as separate tokens (Doubao).
    private func pauseTargets(_ words: [Word], sentenceEnds: Set<UUID>) -> [UUID: Double] {
        let sentence = CharacterSet(charactersIn: "。！？.!?…")
        let comma = CharacterSet(charactersIn: "，,、；;：:")
        var result: [UUID: Double] = [:]
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            guard !word.isPunctuation else { continue }
            var marks = Array(
                word.text.unicodeScalars.reversed().prefix { CharacterSet.punctuationCharacters.contains($0) })
            var ends = sentenceEnds.contains(word.id)
            while index < words.count && words[index].isPunctuation {
                marks += words[index].text.unicodeScalars
                ends = ends || sentenceEnds.contains(words[index].id)
                index += 1
            }
            result[word.id] =
                ends || marks.contains(where: sentence.contains)
                ? settings.sentenceGap
                : marks.contains(where: comma.contains) ? settings.commaGap : settings.wordGap
        }
        return result
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
    /// A phrase restarted at once within a clause: 我们我们决定, 里面包里面包含, 我们都知道 A 我们都知道 AI. The
    /// abandoned start is cut when the words right after it begin with the same text, so exact repeats and
    /// restarts that broke off mid-word are both covered. Returns each cut with the words it removes.
    private func restartedPhrases(_ clauses: [[Word]]) -> [(cut: CutCandidate, words: [Word])] {
        var result: [(cut: CutCandidate, words: [Word])] = []
        for clause in clauses {
            let spoken = clause.filter { !$0.isPunctuation }
            let texts = spoken.map { normalized($0.text) }
            let spokenText = spoken.map(\.text).joined()
            var i = 0
            while i < spoken.count {
                // The longest start of at least two characters that the following words begin with; a single
                // CJK character is often a legitimate reduplication (看看, 人人).
                var size = 0
                var unit = ""
                for k in 1..<max(1, spoken.count - i) {
                    unit += texts[i + k - 1]
                    guard unit.count <= 20 else { break }
                    guard unit.count >= 2 else { continue }
                    var rest = ""
                    for text in texts[(i + k)...] where rest.count < unit.count { rest += text }
                    if rest.hasPrefix(unit) { size = k }
                }
                guard size > 0 else {
                    i += 1
                    continue
                }
                let first = Array(spoken[i..<(i + size)])
                let text = first.map(\.text).joined()
                let offset = spoken[..<i].reduce(0) { $0 + $1.text.count }
                if !Self.isReduplication(text, in: spokenText, at: offset) {
                    let cut = CutCandidate(
                        kind: .retake, start: first.first!.start, end: first.last!.end, text: text,
                        reason: "Immediate repeated phrase")
                    result.append((cut, first))
                }
                i += size
            }
        }
        return result
    }
    /// A restart can follow a few words with no pause in between, so they share a clause: 所以为了 ⏸
    /// 所以为了我们都知道 AI…, where 我们都知道 AI… starts the sentence over. When a clause's first words repeat
    /// the end of the clause before it and the rest opens like an earlier clause, those words belong to the
    /// abandoned take and are cut with it.
    private func strayHeads(_ clauses: [[Word]]) -> [(cut: CutCandidate, words: [Word])] {
        var result: [(cut: CutCandidate, words: [Word])] = []
        let clauseTexts = clauses.map { normalized($0.map(\.text).joined()) }
        var windowStart = 0
        for c in clauses.indices.dropFirst() {
            let spoken = clauses[c].filter { !$0.isPunctuation }
            let texts = spoken.map { normalized($0.text) }
            let previous = clauseTexts[c - 1]
            while spoken[0].start - clauses[windowStart].first!.start > Self.retakeWindow { windowStart += 1 }
            let earlier = clauseTexts[windowStart..<c]
            var head = ""
            for j in 1..<max(1, spoken.count) {
                head += texts[j - 1]
                guard head.count <= 6 else { break }
                let rest = texts[j...].joined()
                guard head.count >= 2, rest.count >= 4, previous.hasSuffix(head) else { continue }
                let opening = String(rest.prefix(6))
                guard earlier.contains(where: { $0.hasPrefix(opening) }) else { continue }
                let words = Array(spoken[..<j])
                let cut = CutCandidate(
                    kind: .retake, start: words.first!.start, end: words.last!.end, text: words.map(\.text).joined(),
                    reason: "End of an abandoned take before a restart")
                result.append((cut, words))
                break
            }
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
            } else if Self.coverage(a, in: Array(prefix), anchored: true).score >= threshold
                || Self.isRewording(a, of: prefix),
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
    /// A later take that opens the same way and says the same thing at more length: 里面有大量，你意思不 →
    /// 里面包含了大量你意想不到的. Words the later take adds cost nothing; three quarters of the earlier take's
    /// characters must appear in it in order.
    static func isRewording(_ a: [Unicode.Scalar], of b: ArraySlice<Unicode.Scalar>) -> Bool {
        guard a.count >= 6, b.starts(with: a.prefix(2)) else { return false }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var row = [0]
            for (j, y) in b.enumerated() { row.append(x == y ? previous[j] + 1 : max(previous[j + 1], row[j])) }
            previous = row
        }
        return Double(previous[b.count]) >= 0.75 * Double(a.count)
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
        // 一步一步, 一点一点: one-by-one reduplication rather than a stutter.
        if Set(unit).count == 1 || (unit.count == 2 && unit.hasPrefix("一")) { return true }
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
