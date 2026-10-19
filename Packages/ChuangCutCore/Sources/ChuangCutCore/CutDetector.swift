import Foundation

public struct CutDetector {
    public var settings: DetectionSettings
    public init(settings: DetectionSettings = DetectionSettings()) { self.settings = settings }
    private let delimiters = CharacterSet(charactersIn: "，。！？,.!?；;：:、\n")
    private func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0)
        }.map(String.init).joined()
    }
    public func clauses(_ words: [Word]) -> [[Word]] {
        var result: [[Word]] = []
        var current: [Word] = []
        for word in words {
            if let last = current.last, word.start - last.end > settings.pauseThreshold {
                result.append(current)
                current = []
            }
            current.append(word)
            if word.text.unicodeScalars.contains(where: { delimiters.contains($0) }) {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { $0.contains { !$0.isPunctuation } }
    }
    public func detect(words: [Word], duration: Double, silences: [TimeRange] = []) -> [CutCandidate] {
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
        let allClauses = clauses(words)
        let fillers = Set(settings.fillers.map(normalized))
        var meaningful: [[Word]] = []
        for clause in allClauses {
            let text = clause.map(\.text).joined()
            let norm = normalized(text)
            // Whole-clause matching protects e.g. “那个视频” and “这个软件”.
            let repeatedFiller = fillers.contains { filler in
                !filler.isEmpty && norm.count >= filler.count * 2
                    && norm.replacingOccurrences(of: filler, with: "").isEmpty
            }
            if fillers.contains(norm) || repeatedFiller {
                let start = clause.first!.start
                let end = max(start + 0.02, clause.map(\.end).max()!)
                candidates.append(
                    CutCandidate(
                        kind: .filler, start: max(0, start - 0.015), end: min(duration, end + 0.015), text: text,
                        reason: "Isolated filler clause"))
            } else {
                meaningful.append(clause)
                // Unambiguous hesitation tokens can occur without punctuation.
                for word in clause
                where ["嗯", "呃", "额", "um", "uh", "er"].contains(normalized(word.text))
                    && fillers.contains(normalized(word.text))
                {
                    candidates.append(
                        CutCandidate(
                            kind: .filler, start: word.start, end: max(word.end, word.start + 0.02), text: word.text,
                            reason: "Hesitation token"))
                }
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
                if Self.similarity(a, b) >= 0.8 || (a.count >= 4 && b.hasPrefix(a)) {
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
