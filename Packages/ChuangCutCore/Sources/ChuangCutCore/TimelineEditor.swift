import Foundation

public enum TrimEdge: String, Codable, Sendable { case left, right }
public struct TrimInstruction: Sendable {
    public let segmentIndex: Int
    public let edge: TrimEdge
    public let sourceTime: Double
    public init(_ argument: String) throws {
        let parts = argument.split(separator: ":")
        guard parts.count == 3, let index = Int(parts[0]), index >= 0, let edge = TrimEdge(rawValue: String(parts[1])), let time = Double(parts[2]), time.isFinite else { throw ChuangCutError.message("Invalid trim. Use <segmentIndex>:<left|right>:<sourceSeconds> (zero-based).") }
        segmentIndex = index; self.edge = edge; sourceTime = time
    }
}
/// All edits modify the candidate set. Playback, subtitles and export derive from TimelineMapper.
public enum TimelineEditor {
    public static func keptSegments(duration: Double, cuts: [CutCandidate], splits: [Double] = []) -> [TimeRange] {
        TimelineMapper(duration: duration, cuts: cuts, splits: splits).keptRanges
    }
    public static func trim(duration: Double, segmentIndex: Int, edge: TrimEdge, newSourceTime: Double, cuts: [CutCandidate], splits: [Double] = [], minimumLength: Double = 0.1) -> [CutCandidate] {
        let kept = keptSegments(duration: duration, cuts: cuts, splits: splits)
        guard kept.indices.contains(segmentIndex), newSourceTime.isFinite else { return cuts }
        let segment = kept[segmentIndex]
        let minimum = min(minimumLength, segment.duration)
        let lower = edge == .left ? (segmentIndex > 0 ? kept[segmentIndex - 1].end : 0) : segment.start + minimum
        let upper = edge == .right ? (segmentIndex + 1 < kept.count ? kept[segmentIndex + 1].start : duration) : segment.end - minimum
        let time = max(lower, min(upper, newSourceTime))
        let old = edge == .left ? segment.start : segment.end
        guard abs(time - old) > 0.000001 else { return cuts }
        var result = cuts
        let shrinking = edge == .left ? time > old : time < old
        if shrinking {
            let removed = TimeRange(min(time, old), max(time, old))
            // Extend the candidate that touches this side of the adjacent union, preserving identity.
            if let index = result.indices.first(where: {
                result[$0].enabled && (edge == .left ? abs(result[$0].sourceEnd - old) < 0.001 : abs(result[$0].sourceStart - old) < 0.001)
            }) {
                if edge == .left { result[index].sourceEnd = time } else { result[index].sourceStart = time }
                result[index].isAdjusted = true
            } else {
                var cut = CutCandidate(kind: .manual, start: removed.start, end: removed.end, text: "Trim", reason: "Clip edge adjusted")
                cut.isAdjusted = true; result.append(cut)
            }
        } else {
            let restored = TimeRange(min(time, old), max(time, old))
            // Every overlapping candidate must be shortened, including those buried inside the union.
            for i in result.indices where result[i].enabled && result[i].sourceEnd > restored.start && result[i].sourceStart < restored.end {
                result[i].isAdjusted = true
                if restored.start <= result[i].sourceStart + 0.000001 && restored.end >= result[i].sourceEnd - 0.000001 {
                    result[i].enabled = false // Keep valid original bounds for inspection and undo.
                } else if edge == .right { result[i].sourceStart = max(result[i].sourceStart, restored.end) }
                else { result[i].sourceEnd = min(result[i].sourceEnd, restored.start) }
            }
        }
        return result.sorted { $0.sourceStart < $1.sourceStart }
    }
    public static func snap(_ proposed: Double, words: [Word], extra: [Double] = [], tolerance: Double) -> Double? {
        (words.flatMap { [$0.start, $0.end] } + extra).filter { abs($0 - proposed) <= max(0, tolerance) }
            .min { abs($0 - proposed) == abs($1 - proposed) ? $0 < $1 : abs($0 - proposed) < abs($1 - proposed) }
    }
}
