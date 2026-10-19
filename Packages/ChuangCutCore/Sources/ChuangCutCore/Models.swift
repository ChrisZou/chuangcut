import Foundation

public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }
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
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
    private static let punctuationOrSpace = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
    public var isPunctuation: Bool { text.unicodeScalars.allSatisfy { Self.punctuationOrSpace.contains($0) } }
}
public typealias Token = Word
public struct Segment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]
    public init(start: Double, end: Double, text: String, words: [Word]) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}
public struct Transcript: Codable, Equatable, Sendable {
    public var segments: [Segment]
    public var language: String
    public init(segments: [Segment], language: String = "zh") {
        self.segments = segments
        self.language = language
        normalizePunctuation()
    }
    enum CodingKeys: String, CodingKey { case segments, language }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            segments: try c.decode([Segment].self, forKey: .segments),
            language: try c.decodeIfPresent(String.self, forKey: .language) ?? "zh")
    }
    public var words: [Word] { segments.flatMap(\.words) }
}
public enum CutKind: String, Codable, CaseIterable, Sendable { case pause, retake, filler, manual }
public struct CutCandidate: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var kind: CutKind
    public var sourceStart: Double { didSet { refreshPauseText() } }
    public var sourceEnd: Double { didSet { refreshPauseText() } }
    public var text: String
    public var reason: String
    public var enabled: Bool
    public var isAdjusted: Bool? = nil
    public init(kind: CutKind, start: Double, end: Double, text: String = "", reason: String, enabled: Bool = true) {
        self.kind = kind
        sourceStart = start
        sourceEnd = end
        self.text = text
        self.reason = reason
        self.enabled = enabled
        refreshPauseText()
    }
    private mutating func refreshPauseText() {
        if kind == .pause { text = String(format: "⏸ %.1fs", max(0, sourceEnd - sourceStart)) }
    }
    enum CodingKeys: String, CodingKey { case id, kind, sourceStart, sourceEnd, text, reason, enabled, isAdjusted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decode(CutKind.self, forKey: .kind), start: try c.decode(Double.self, forKey: .sourceStart),
            end: try c.decode(Double.self, forKey: .sourceEnd), text: try c.decode(String.self, forKey: .text),
            reason: try c.decode(String.self, forKey: .reason), enabled: try c.decode(Bool.self, forKey: .enabled))
        id = try c.decode(UUID.self, forKey: .id)
        isAdjusted = try c.decodeIfPresent(Bool.self, forKey: .isAdjusted)
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
    public var replaceInnerPunctuationWithSpaces = true
    public init() {}
    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, colorHex, outline, bottomMargin, cjkLineLength, latinLineLength,
            replaceInnerPunctuationWithSpaces
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? colorHex
        outline = try c.decodeIfPresent(Double.self, forKey: .outline) ?? outline
        bottomMargin = try c.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? bottomMargin
        cjkLineLength = try c.decodeIfPresent(Int.self, forKey: .cjkLineLength) ?? cjkLineLength
        latinLineLength = try c.decodeIfPresent(Int.self, forKey: .latinLineLength) ?? latinLineLength
        replaceInnerPunctuationWithSpaces =
            try c.decodeIfPresent(Bool.self, forKey: .replaceInnerPunctuationWithSpaces) ?? true
    }
}
public struct MediaInfo: Codable, Sendable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var bitrate: Int
    public var hasAudio: Bool
    public var frameRate: Double? = nil
}
public struct Project: Codable, Sendable {
    public var source: URL
    public var media: MediaInfo
    public var transcript: Transcript?
    public var candidates: [CutCandidate]
    public var silences: [TimeRange]
    public var splitPoints: [Double]? = nil
    public init(
        source: URL, media: MediaInfo, transcript: Transcript? = nil, candidates: [CutCandidate] = [],
        silences: [TimeRange] = []
    ) {
        self.source = source
        self.media = media
        self.transcript = transcript
        self.candidates = candidates
        self.silences = silences
    }
    public var mapper: TimelineMapper {
        TimelineMapper(duration: media.duration, cuts: candidates, splits: splitPoints ?? [])
    }
}
public enum ChuangCutError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
public enum JSONFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
public func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains {
        (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value)
            || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
    }
}
