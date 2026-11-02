import Foundation

/// The soundtrack's level every 10 ms, used to put cut edges where speech starts and stops. ASR timestamps
/// can be a few frames off; the level shows the frame where a word becomes audible.
public struct Loudness: Sendable {
    public static let frame = 0.01
    /// dBFS per frame.
    public var levels: [Float]
    /// The room's background level, the quietest tenth of the recording.
    public let floor: Float
    public init(levels: [Float]) {
        self.levels = levels
        let sorted = levels.sorted()
        floor = sorted.isEmpty ? -90 : sorted[sorted.count / 10]
    }
    /// Level at which speech is unmistakable, and the lower level its soft attack (s, c, f) rises from. A
    /// digitally silent background would otherwise make reverb tails count as speech.
    var clear: Float { min(max(floor + 20, -50), -25) }
    var soft: Float { clear - 12 }
    private func index(_ time: Double) -> Int { min(levels.count, max(0, Int((time / Self.frame).rounded()))) }
    /// Where the first clearly audible sound in `lower..<upper` begins, including the quieter attack before it.
    func onset(from lower: Double, to upper: Double) -> Double? {
        let first = index(lower)
        guard let loud = (first..<index(upper)).first(where: { levels[$0] >= clear }) else { return nil }
        var start = loud
        while start > first && levels[start - 1] >= soft { start -= 1 }
        return Double(start) * Self.frame
    }
    /// The longest stretch of `lower..<upper` in which nothing is clearly audible.
    func longestQuiet(from lower: Double, to upper: Double) -> TimeRange? {
        var best: Range<Int>?
        var start: Int?
        let end = index(upper)
        guard index(lower) < end else { return nil }
        for i in index(lower)...end {
            if i < end && levels[i] < clear {
                if start == nil { start = i }
            } else if let first = start {
                if (best?.count ?? 0) < i - first { best = first..<i }
                start = nil
            }
        }
        return best.map { TimeRange(Double($0.lowerBound) * Self.frame, Double($0.upperBound) * Self.frame) }
    }
    /// Where the last clearly audible sound in `lower..<upper` ends.
    func offset(from lower: Double, to upper: Double) -> Double? {
        let first = index(lower)
        guard let loud = (first..<index(upper)).last(where: { levels[$0] >= clear }) else { return nil }
        return Double(loud + 1) * Self.frame
    }
}
