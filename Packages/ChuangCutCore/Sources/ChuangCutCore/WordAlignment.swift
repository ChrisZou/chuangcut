import Foundation

extension Transcript {
    /// Whisper segment boundaries often absorb neighbouring silence: the first word of a segment can
    /// start long before the speaker does, and the last can run into the next pause. Pause cuts come
    /// from acoustic silence, so such words would look cut while their audio is kept. Trim word spans
    /// to speech and move words that lie entirely inside a silence back to the speech they belong to.
    public func aligned(to silences: [TimeRange]) -> Transcript {
        let gaps = TimelineMapper.merge(silences)
        guard !gaps.isEmpty else { return self }
        var result = self
        for index in result.segments.indices {
            result.segments[index].words = Self.align(result.segments[index].words, gaps: gaps)
        }
        return result
    }

    internal static func align(_ original: [Word], gaps: [TimeRange]) -> [Word] {
        var words = original
        // The silence that wholly contains each word, if any.
        var inside = [Int?](repeating: nil, count: words.count)
        for i in words.indices {
            let word = words[i]
            let first = TimelineMapper.firstIndex(count: gaps.count) { gaps[$0].end > word.start }
            if first < gaps.count, gaps[first].start <= word.start, word.end <= gaps[first].end {
                inside[i] = first
                continue
            }
            if first < gaps.count, gaps[first].start <= word.start {
                words[i].start = gaps[first].end
            } else if first < gaps.count, gaps[first].end < word.end {
                // A silence inside the word: Whisper stretched it over the pause, so it was said on the
                // longer side.
                if gaps[first].start - word.start >= word.end - gaps[first].end {
                    words[i].end = gaps[first].start
                } else {
                    words[i].start = gaps[first].end
                }
            }
            let last = TimelineMapper.firstIndex(count: gaps.count) { gaps[$0].end >= word.end }
            if last < gaps.count, gaps[last].start < word.end, gaps[last].start > words[i].start {
                words[i].end = gaps[last].start
            }
        }
        var a = 0
        while a < words.count {
            guard let gapIndex = inside[a] else {
                a += 1
                continue
            }
            var b = a
            while b + 1 < words.count, inside[b + 1] == gapIndex { b += 1 }
            defer { a = b + 1 }
            let gap = gaps[gapIndex]
            let atStart = a == 0
            let atEnd = b == words.count - 1
            // A whole segment inside a silence has nothing to anchor to; leave it untouched.
            if atStart && atEnd { continue }
            let forward =
                atStart || (!atEnd && (original[a].start + original[b].end) / 2 >= (gap.start + gap.end) / 2)
            if forward {
                // Share the following word's span: the run is its leading syllables.
                if inside[b + 1] == nil {
                    spread(&words, a...(b + 1), from: gap.end, to: max(gap.end, words[b + 1].end))
                } else {
                    spread(&words, a...b, from: gap.end, to: gap.end)
                }
            } else if inside[a - 1] == nil {
                spread(&words, (a - 1)...b, from: min(words[a - 1].start, gap.start), to: gap.start)
            } else {
                spread(&words, a...b, from: gap.start, to: gap.start)
            }
        }
        return words
    }

    private static func spread(_ words: inout [Word], _ range: ClosedRange<Int>, from start: Double, to end: Double) {
        let step = (end - start) / Double(range.count)
        for (offset, index) in range.enumerated() {
            words[index].start = start + step * Double(offset)
            words[index].end = start + step * Double(offset + 1)
        }
    }
}
