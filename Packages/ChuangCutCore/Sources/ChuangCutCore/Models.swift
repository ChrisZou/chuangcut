import Foundation

public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
    public var duration: Double { max(0, end - start) }
    public func contains(_ time: Double) -> Bool { time >= start && time < end }
}
public struct Word: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double
    public init(text: String, start: Double, end: Double, confidence: Double = 1, id: UUID = UUID()) {
        self.id = id; self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
    public var isPunctuation: Bool { text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0) } }
}
public typealias Token = Word
public struct Segment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]
    public init(start: Double, end: Double, text: String, words: [Word]) { self.start = start; self.end = end; self.text = text; self.words = words }
}
public struct Transcript: Codable, Equatable, Sendable {
    public var segments: [Segment]
    public var language: String
    public init(segments: [Segment], language: String = "zh") { self.segments = segments; self.language = language }
    public var words: [Word] { segments.flatMap(\.words) }
}
public enum CutKind: String, Codable, CaseIterable, Sendable { case pause, retake, filler, manual }
public struct CutCandidate: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var kind: CutKind
    public var sourceStart: Double
    public var sourceEnd: Double
    public var text: String
    public var reason: String
    public var enabled: Bool
    public init(kind: CutKind, start: Double, end: Double, text: String = "", reason: String, enabled: Bool = true) {
        self.kind = kind; sourceStart = start; sourceEnd = end; self.text = text; self.reason = reason; self.enabled = enabled
    }
    public var range: TimeRange { TimeRange(sourceStart, sourceEnd) }
}
public struct DetectionSettings: Codable, Sendable {
    public var pauseThreshold: Double = 0.6
    public var padding: Double = 0.10
    public var fillers: [String] = ["嗯", "啊", "呃", "额", "那个", "就是说", "然后呢", "这个", "um", "uh", "er", "ah"]
    public init() {}
}
public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var fontName = "PingFang SC"
    public var fontSize: Double = 38
    public var colorHex = "FFFFFF"
    public var outline: Double = 2
    public var bottomMargin: Double = 42
    public var cjkLineLength = 16
    public var latinLineLength = 42
    public init() {}
}
public struct MediaInfo: Codable, Sendable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var bitrate: Int
    public var hasAudio: Bool
}
public struct Project: Codable, Sendable {
    public var source: URL
    public var media: MediaInfo
    public var transcript: Transcript?
    public var candidates: [CutCandidate]
    public var silences: [TimeRange]
    public init(source: URL, media: MediaInfo, transcript: Transcript? = nil, candidates: [CutCandidate] = [], silences: [TimeRange] = []) {
        self.source = source; self.media = media; self.transcript = transcript; self.candidates = candidates; self.silences = silences
    }
    public var mapper: TimelineMapper { TimelineMapper(duration: media.duration, cuts: candidates) }
}
public enum ChuangCutError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public enum JSONFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
public func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
}
