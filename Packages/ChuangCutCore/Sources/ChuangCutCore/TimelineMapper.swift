import Foundation

public struct TimelineMapper: Sendable {
    public let duration: Double
    public let cutRanges: [TimeRange]
    public let keptRanges: [TimeRange]
    public let editedDuration: Double
    /// Removed duration before each cut range and edited time at each kept range, so time
    /// mapping and word classification are binary searches instead of linear scans.
    private let cutOffsets: [Double]
    private let keptOffsets: [Double]
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
        cutOffsets = Self.offsets(cutRanges)
        keptOffsets = Self.offsets(keptRanges)
        editedDuration = (keptOffsets.last ?? 0) + (keptRanges.last?.duration ?? 0)
    }
    private static func offsets(_ ranges: [TimeRange]) -> [Double] {
        var total = 0.0
        return ranges.map { range in
            defer { total += range.duration }
            return total
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
        let index = Self.firstIndex(count: cutRanges.count) { cutRanges[$0].start >= t }
        guard index > 0 else { return t }
        let cut = cutRanges[index - 1]
        return max(0, t - cutOffsets[index - 1] - (min(t, cut.end) - cut.start))
    }
    public func cutToSource(_ time: Double) -> Double {
        let remaining = max(0, time)
        let index = Self.firstIndex(count: keptRanges.count) { keptOffsets[$0] + keptRanges[$0].duration > remaining }
        guard index < keptRanges.count else { return keptRanges.last?.end ?? 0 }
        return keptRanges[index].start + remaining - keptOffsets[index]
    }
    /// Binary search for the first element satisfying a predicate that is monotonic over the array.
    static func firstIndex(count: Int, where predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(mid) { high = mid } else { low = mid + 1 }
        }
        return low
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
    public func removes(_ word: Word) -> Bool {
        if word.end <= word.start {
            let index = Self.firstIndex(count: cutRanges.count) { cutRanges[$0].end > word.start }
            return index < cutRanges.count && cutRanges[index].contains(word.start)
        }
        // cutRanges are merged and sorted, so only the few ranges touching the word are summed.
        var overlap = 0.0
        var index = Self.firstIndex(count: cutRanges.count) { cutRanges[$0].end > word.start }
        while index < cutRanges.count, cutRanges[index].start < word.end {
            overlap += Self.overlapDuration(word, range: cutRanges[index])
            index += 1
        }
        return overlap > (word.end - word.start) / 2 + 1e-9
    }

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
    /// `candidate(for:cuts:)` for a whole transcript. Candidates are indexed by start with a running
    /// maximum end, so each word only inspects the candidates that can touch it.
    public func candidates(for words: [Word], cuts: [CutCandidate]) -> [CutCandidate?] {
        let order = cuts.indices.sorted { cuts[$0].sourceStart < cuts[$1].sourceStart }
        var maxEnd: [Double] = []
        for index in order { maxEnd.append(max(maxEnd.last ?? -.infinity, cuts[index].sourceEnd)) }
        return words.map { word in
            var k = Self.firstIndex(count: order.count) { maxEnd[$0] >= word.start }
            var nearby: [Int] = []
            while k < order.count, cuts[order[k]].sourceStart <= word.end {
                nearby.append(order[k])
                k += 1
            }
            // Original order keeps the same tie-break as the single-word lookup.
            return candidate(for: word, cuts: nearby.sorted().map { cuts[$0] })
        }
    }
    /// Place a pause capsule before the first word classified as cut, including a boundary
    /// inside that word. Otherwise insert after the partially retained word, in time order.
    public func pauseInsertionIndex(_ cut: CutCandidate, words: [Word]) -> Int {
        words.firstIndex { word in
            word.start >= cut.sourceStart
                || (Self.overlapDuration(word, range: cut.range) > 0
                    && (cut.enabled ? removes(word) : Self.removes(word, in: [cut.range])))
        } ?? words.count
    }
}
