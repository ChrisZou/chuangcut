import Foundation

public struct TimelineMapper: Sendable {
    public let duration: Double
    public let cutRanges: [TimeRange]
    public let keptRanges: [TimeRange]
    public var editedDuration: Double { keptRanges.reduce(0) { $0 + $1.duration } }
    public init(duration: Double, cuts: [CutCandidate], splits: [Double] = []) {
        self.duration = max(0, duration)
        cutRanges = Self.merge(
            cuts.filter(\.enabled).map { TimeRange(max(0, $0.sourceStart), min(duration, $0.sourceEnd)) })
        var kept: [TimeRange] = []
        var cursor = 0.0
        for cut in cutRanges {
            if cut.start > cursor { kept.append(TimeRange(cursor, cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < duration { kept.append(TimeRange(cursor, duration)) }
        keptRanges = kept.flatMap { range -> [TimeRange] in
            let points =
                [range.start]
                + Array(Set(splits.filter { $0 > range.start + 0.000001 && $0 < range.end - 0.000001 })).sorted() + [
                    range.end
                ]
            return zip(points, points.dropFirst()).map { TimeRange($0.0, $0.1) }
        }
    }
    public static func merge(_ ranges: [TimeRange]) -> [TimeRange] {
        var result: [TimeRange] = []
        for range in ranges.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end + 0.001 {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
    /// A point inside a removed interval maps to its join on the edited timeline.
    public func sourceToCut(_ time: Double) -> Double {
        let t = min(duration, max(0, time))
        return max(0, t - cutRanges.reduce(0) { $0 + max(0, min(t, $1.end) - $1.start) })
    }
    public func cutToSource(_ time: Double) -> Double {
        var remaining = max(0, time)
        for range in keptRanges {
            if remaining < range.duration { return range.start + remaining }
            remaining -= range.duration
        }
        return keptRanges.last?.end ?? 0
    }
    /// Strict majority of the word's duration, using the union so overlaps never double-count.
    /// Zero-duration ASR tokens use half-open point membership; an exact 50% tie is kept.
    public static func removes(_ word: Word, in ranges: [TimeRange]) -> Bool {
        if word.end <= word.start { return ranges.contains { $0.contains(word.start) } }
        let overlap = merge(ranges).reduce(0.0) { $0 + overlapDuration(word, range: $1) }
        return overlap > (word.end - word.start) / 2 + 1e-9
    }
    public static func overlapDuration(_ word: Word, range: TimeRange) -> Double {
        max(0, min(word.end, range.end) - max(word.start, range.start))
    }
    public func removes(_ word: Word) -> Bool { Self.removes(word, in: cutRanges) }

    /// Attribute a removed word to the candidate covering most of it, even when a union of
    /// several candidates supplies the majority. Kept words may show a disabled suggestion.
    public func candidate(for word: Word, cuts: [CutCandidate]) -> CutCandidate? {
        let removed = removes(word)
        return cuts.filter { cut in
            if removed {
                return cut.enabled
                    && (Self.overlapDuration(word, range: cut.range) > 0
                        || (word.end <= word.start && cut.range.contains(word.start)))
            }
            return !cut.enabled && Self.removes(word, in: [cut.range])
        }.max { Self.overlapDuration(word, range: $0.range) < Self.overlapDuration(word, range: $1.range) }
    }
    /// Place a pause capsule before the first word classified as cut, including a boundary
    /// inside that word. Otherwise insert after the partially retained word, in time order.
    public func pauseInsertionIndex(_ cut: CutCandidate, words: [Word]) -> Int {
        words.firstIndex { word in
            word.start >= cut.sourceStart
                || ((cut.enabled ? removes(word) : Self.removes(word, in: [cut.range]))
                    && Self.overlapDuration(word, range: cut.range) > 0)
        } ?? words.count
    }
}
