import XCTest
@testable import ChuangCutCore

final class TimelineEditorTests: XCTestCase {
    func cut(_ start: Double, _ end: Double, kind: CutKind = .pause) -> CutCandidate { CutCandidate(kind: kind, start: start, end: end, reason: "test") }
    func words(_ text: String) -> [Word] { text.enumerated().map { Word(text: String($0.element), start: Double($0.offset) * 0.15, end: Double($0.offset + 1) * 0.15) } }
    func testRightShrinkCreatesAndExtendsCut() {
        var cuts = TimelineEditor.trim(duration: 10, segmentIndex: 0, edge: .right, newSourceTime: 8, cuts: [])
        XCTAssertEqual(cuts.first?.kind, .manual)
        XCTAssertEqual(cuts.first?.range, TimeRange(8, 10))
        cuts = TimelineEditor.trim(duration: 10, segmentIndex: 0, edge: .right, newSourceTime: 7, cuts: cuts)
        XCTAssertEqual(cuts.count, 1); XCTAssertEqual(cuts[0].sourceStart, 7)
        XCTAssertEqual(cuts[0].isAdjusted, true)
    }
    func testGrowShrinksPauseAndClampsMergedGap() {
        let initial = [cut(2, 5), cut(4, 6, kind: .retake), cut(5.5, 7, kind: .filler)]
        let partly = TimelineEditor.trim(duration: 10, segmentIndex: 0, edge: .right, newSourceTime: 4.5, cuts: initial)
        XCTAssertEqual(TimelineMapper(duration: 10, cuts: partly).keptRanges, [TimeRange(0, 4.5), TimeRange(7, 10)])
        XCTAssertEqual(partly.filter(\.enabled).map(\.sourceStart), [4.5, 4.5, 5.5])
        let fully = TimelineEditor.trim(duration: 10, segmentIndex: 0, edge: .right, newSourceTime: 9, cuts: initial)
        XCTAssertTrue(fully.allSatisfy { !$0.enabled && $0.sourceEnd > $0.sourceStart })
        XCTAssertEqual(TimelineMapper(duration: 10, cuts: fully).keptRanges, [TimeRange(0, 10)])
        XCTAssertEqual(fully.filter { $0.isAdjusted == true }.count, 3)
    }
    func testLeftEdgeAndMinimumLength() {
        let cuts = TimelineEditor.trim(duration: 10, segmentIndex: 0, edge: .left, newSourceTime: 12, cuts: [])
        XCTAssertEqual(cuts[0].range, TimeRange(0, 9.9))
        let grown = TimelineEditor.trim(duration: 10, segmentIndex: 1, edge: .left, newSourceTime: 4, cuts: [cut(2, 5), cut(4, 7)])
        XCTAssertEqual(TimelineMapper(duration: 10, cuts: grown).keptRanges, [TimeRange(0, 2), TimeRange(4, 10)])
    }
    func testSnapAndPersistedSplit() throws {
        XCTAssertEqual(TimelineEditor.snap(1.07, words: [Word(text: "hello", start: 1, end: 2)], extra: [1.1], tolerance: 0.1), 1.1)
        XCTAssertNil(TimelineEditor.snap(3, words: [], extra: [1], tolerance: 0.1))
        XCTAssertEqual(TimelineMapper(duration: 10, cuts: [], splits: [4, 4]).keptRanges, [TimeRange(0, 4), TimeRange(4, 10)])
        XCTAssertThrowsError(try TrimInstruction("0:left:nan"))
        let cuts = TimelineEditor.trim(duration: 10, segmentIndex: 0, edge: .right, newSourceTime: 3, cuts: [], splits: [4])
        XCTAssertEqual(TimelineMapper(duration: 10, cuts: cuts, splits: [4]).keptRanges, [TimeRange(0, 3), TimeRange(4, 10)])
    }
    func testTrimRetimesAndExcludesWords() {
        let input = [Word(text: "First", start: 0, end: 1), Word(text: " remove", start: 1, end: 2), Word(text: " kept", start: 4, end: 5)]
        let cuts = TimelineEditor.trim(duration: 6, segmentIndex: 0, edge: .right, newSourceTime: 1, cuts: [cut(2, 4)])
        let cues = SubtitleBuilder().build(words: input, mapper: TimelineMapper(duration: 6, cuts: cuts))
        XCTAssertFalse(cues.map(\.text).joined().contains("remove"))
        XCTAssertEqual(cues.last!.end, 2, accuracy: 0.001)
    }
    func testChineseNormalizationAndSubtitleConvention() throws {
        let text = "大家好,欢迎来到我的频道!"
        let transcript = Transcript(segments: [Segment(start: 0, end: 4, text: text, words: words(text))])
        XCTAssertEqual(transcript.segments[0].text, "大家好，欢迎来到我的频道！")
        XCTAssertEqual(transcript.words.map(\.text).joined(), transcript.segments[0].text)
        var legacy = transcript; legacy.segments[0].text = text; legacy.segments[0].words = words(text)
        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.segments[0].text, transcript.segments[0].text)
        XCTAssertEqual(decoded.words.map(\.text), transcript.words.map(\.text))
        XCTAssertEqual(TextNormalization.cjkPunctuation("Hello, world! Why?"), "Hello, world! Why?")
        let builder = SubtitleBuilder()
        let cues = builder.build(words: transcript.words, mapper: TimelineMapper(duration: 5, cuts: []))
        XCTAssertEqual(cues.first?.text, "大家好 欢迎来到我的频道")
        var style = SubtitleStyle(); style.replaceInnerPunctuationWithSpaces = false
        XCTAssertEqual(SubtitleBuilder(style: style).build(words: transcript.words, mapper: TimelineMapper(duration: 5, cuts: [])).first?.text, "大家好，欢迎来到我的频道")
        XCTAssertTrue(try JSONDecoder().decode(SubtitleStyle.self, from: Data("{}".utf8)).replaceInnerPunctuationWithSpaces)
        let internalText = Word(text: "真的？当然！接着：继续；前进、结束。", start: 0, end: 3)
        XCTAssertEqual(builder.build(words: [internalText], mapper: TimelineMapper(duration: 4, cuts: [])).first?.text, "真的？当然！接着 继续 前进 结束")
    }
    func testBalancedChineseAndMiddlePunctuation() {
        for text in ["然后，软件会自动识别停顿和重复的句子。", "软件会自动识别停顿和重复的句子并完成视频剪辑。", "首先我们导入视频，然后自动识别字幕，最后导出剪辑结果。"] {
            let cues = SubtitleBuilder().build(words: words(text), mapper: TimelineMapper(duration: 10, cuts: []))
            XCTAssertGreaterThan(cues.count, 1)
            XCTAssertTrue(cues.allSatisfy { $0.text.filter(isCJK).count >= 4 && $0.text.count <= 16 }, "\(cues)")
            if text.hasPrefix("然后") { XCTAssertEqual(cues.map(\.text), ["然后 软件会自动识别", "停顿和重复的句子"]) }
        }
        let short = SubtitleBuilder().build(words: words("大家好。"), mapper: TimelineMapper(duration: 2, cuts: []))
        XCTAssertEqual(short.first?.text, "大家好")
    }
}
