import XCTest

@testable import ChuangCutCore

final class CoreTests: XCTestCase {
    func words(_ text: String, from: Double = 0, step: Double = 0.15) -> [Word] {
        text.enumerated().map {
            Word(
                text: String($0.element), start: from + Double($0.offset) * step,
                end: from + Double($0.offset + 1) * step)
        }
    }
    func testMergedWhisperSegmentDetectsFirstTakeAndFillers() throws {
        let data = try Data(
            contentsOf: Bundle.module.url(forResource: "whisper", withExtension: "json", subdirectory: "Fixtures")!)
        let transcript = try WhisperRunner.parse(data)
        XCTAssertEqual(transcript.segments.count, 5)
        XCTAssertEqual(transcript.words.map(\.text).joined(), transcript.segments.map(\.text).joined())
        let cuts = CutDetector().detect(words: transcript.words, duration: 25.19)
        let retake = try XCTUnwrap(cuts.first { $0.kind == .retake })
        // The first take runs from 4.48 s to 7.16 s and takes in the padding of the pauses around it.
        XCTAssertEqual(retake.sourceStart, 4.38, accuracy: 0.05)
        XCTAssertEqual(retake.sourceEnd, 7.26, accuracy: 0.05)
        XCTAssertEqual(cuts.filter { $0.kind == .filler }.count, 2)
        XCTAssertFalse(cuts.contains { $0.kind == .retake && $0.sourceStart > 8 })
        XCTAssertGreaterThanOrEqual(cuts.filter { $0.kind == .pause }.count, 4)
    }
    func testDoubaoWordsKeepTheirOwnTimes() throws {
        let json = #"""
            {"result":{"utterances":[{"start_time":5530,"end_time":7290,"text":"我们都知道 AI 已经，我们",
            "words":[{"start_time":5530,"end_time":5730,"text":"我"},{"start_time":5730,"end_time":5810,"text":"们"},
            {"start_time":5810,"end_time":5930,"text":"都"},{"start_time":5930,"end_time":6050,"text":"知"},
            {"start_time":6050,"end_time":6170,"text":"道"},{"start_time":-1,"end_time":-1,"text":" "},
            {"start_time":6250,"end_time":6410,"text":"AI"},{"start_time":-1,"end_time":-1,"text":" "},
            {"start_time":6490,"end_time":6650,"text":"已"},{"start_time":6650,"end_time":6770,"text":"经"},
            {"start_time":7090,"end_time":7170,"text":"我"},{"start_time":7170,"end_time":7290,"text":"们"}]}]}}
            """#
        let transcript = try DoubaoRunner.parse(Data(json.utf8))
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].start, 5.53, accuracy: 0.001)
        XCTAssertEqual(transcript.words.map(\.text), ["我", "们", "都", "知", "道", " AI", "已", "经", "，", "我", "们"])
        XCTAssertEqual(transcript.words[5].start, 6.25, accuracy: 0.001)
        XCTAssertEqual(transcript.words[5].end, 6.41, accuracy: 0.001)
        // Punctuation sits at the end of the word before it, taking no time.
        XCTAssertEqual(transcript.words[8].start, 6.77, accuracy: 0.001)
        XCTAssertEqual(transcript.words[8].end, 6.77, accuracy: 0.001)
    }
    func testFillerContextAndFalseStart() {
        let input = words("那个视频很好。这个软件很好。嗯，那个，今天我们来聊。今天我们来聊视频剪辑。")
        let cuts = CutDetector().detect(words: input, duration: 20)
        XCTAssertEqual(cuts.filter { $0.kind == .filler }.count, 2)
        XCTAssertTrue(cuts.contains { $0.kind == .retake && $0.text == "今天我们来聊。" })
        XCTAssertFalse(cuts.contains { $0.kind == .filler && $0.sourceStart < 2 })
    }
    func testStutterKeepsLastAndDoesNotCutReduplication() {
        let input = words("我们我们需要看看视频。")
        let cuts = CutDetector().detect(words: input, duration: 3)
        XCTAssertEqual(cuts.filter { $0.kind == .retake }.map(\.text), ["我们"])
    }
    func testAcousticPausesAndPadding() {
        var settings = DetectionSettings()
        settings.padding = 0.1
        let cuts = CutDetector(settings: settings).detect(
            words: words("你好"), duration: 10, silences: [TimeRange(1, 2.5), TimeRange(4, 5.3), TimeRange(7, 8)])
        XCTAssertEqual(cuts.filter { $0.kind == .pause }.count, 3)
        XCTAssertEqual(cuts.first!.sourceStart, 1.1, accuracy: 0.001)
        XCTAssertEqual(cuts.first!.sourceEnd, 2.4, accuracy: 0.001)
    }
    func testSpeechCutsMeetAcousticPauses() {
        let input = words("今天我们来聊。", from: 2) + words("今天我们来聊。", from: 5)
        let cuts = CutDetector().detect(words: input, duration: 9, silences: [TimeRange(0.5, 2), TimeRange(3.2, 4.9)])
        let retake = cuts.first { $0.kind == .retake }!
        XCTAssertEqual(retake.sourceStart, 1.9, accuracy: 0.001)
        XCTAssertEqual(retake.sourceEnd, 3.3, accuracy: 0.001)
        XCTAssertEqual(TimelineMapper(duration: 9, cuts: cuts).cutRanges.count, 1)
    }
    func testRepeatedContextualFiller() {
        let cuts = CutDetector().detect(words: words("那个那个，我们开始。"), duration: 5)
        XCTAssertEqual(cuts.filter { $0.kind == .filler }.map(\.text), ["那个那个，"])
    }
    func testTimelineMergesOverlapClampsAndHonorsDisabled() {
        let cuts = [
            CutCandidate(kind: .manual, start: -2, end: 2, reason: ""),
            CutCandidate(kind: .retake, start: 1, end: 3, reason: ""),
            CutCandidate(kind: .pause, start: 6, end: 8, reason: "", enabled: false),
            CutCandidate(kind: .manual, start: 9, end: 12, reason: ""),
        ]
        let map = TimelineMapper(duration: 10, cuts: cuts)
        XCTAssertEqual(map.keptRanges, [TimeRange(3, 9)])
        XCTAssertEqual(map.editedDuration, 6)
        XCTAssertEqual(map.sourceToCut(1), 0)
        XCTAssertEqual(map.sourceToCut(5), 2)
        XCTAssertEqual(map.cutToSource(2), 5)
        XCTAssertEqual(map.cutToSource(100), 9)
    }
    func testSubtitlePunctuationLengthAndMapping() {
        let input = words("嗯，今天我们来聊视频剪辑，软件会自动识别停顿和重复的句子。最后导出。")
        let filler = CutCandidate(kind: .filler, start: 0, end: 0.3, reason: "")
        let map = TimelineMapper(duration: 10, cuts: [filler])
        var style = SubtitleStyle()
        style.cjkLineLength = 10
        let builder = SubtitleBuilder(style: style)
        let cues = builder.build(words: input, mapper: map, fillers: [filler])
        XCTAssertFalse(cues.map(\.text).joined().contains("嗯"))
        for (i, cue) in cues.enumerated() {
            XCTAssertLessThanOrEqual(cue.text.count, 10)
            XCTAssertFalse("。，！？、,.".contains(cue.text.last!))
            XCTAssertLessThanOrEqual(cue.end, map.editedDuration)
            XCTAssertGreaterThan(cue.end, cue.start)
            if i > 0 { XCTAssertGreaterThanOrEqual(cue.start, cues[i - 1].end) }
        }
        XCTAssertTrue(builder.srt(cues).contains(" --> "))
        XCTAssertTrue(builder.ass(cues, width: 1280, height: 720).contains("PingFang SC"))
    }
    func testLatinWordsNotSplit() {
        let input = ["Hello", " wonderful", " world", " this", " is", " ChuangCut", "."].enumerated().map {
            Word(text: $0.element, start: Double($0.offset), end: Double($0.offset + 1))
        }
        var style = SubtitleStyle()
        style.latinLineLength = 18
        let cues = SubtitleBuilder(style: style).build(words: input, mapper: TimelineMapper(duration: 8, cuts: []))
        XCTAssertEqual(cues.map(\.text).joined(separator: " "), "Hello wonderful world this is ChuangCut")
    }
    func testByteFragmentsAndLatinSubwords() throws {
        let json =
            #"{"transcription":[{"offsets":{"from":0,"to":1000},"text":"剪辑 hello","tokens":[{"text":"剪","offsets":{"from":0,"to":200}},{"text":"�","offsets":{"from":200,"to":300}},{"text":"�","offsets":{"from":300,"to":400}},{"text":" hel","offsets":{"from":500,"to":700}},{"text":"lo","offsets":{"from":700,"to":1000}}]}]}"#
        let transcript = try WhisperRunner.parse(Data(json.utf8))
        XCTAssertEqual(transcript.words.map(\.text), ["剪", "辑", " hello"])
        XCTAssertTrue(transcript.words.allSatisfy { $0.end >= $0.start })
    }
    func testSilenceParserTrailingAndLeading() {
        let ranges = FFmpegRunner.parseSilences(
            "silence_end: 1.2 | silence_duration: 1.2\nsilence_start: 5.5", duration: 7)
        XCTAssertEqual(ranges, [TimeRange(0, 1.2), TimeRange(5.5, 7)])
    }
    func testCancellationBeforeLaunch() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/echo", ["test"], cancellation: token)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
    func testCancellationTerminatesRunningProcess() {
        let token = CancellationToken()
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["10"], cancellation: token)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testLeadingAndTrailingPauses() {
        let cuts = CutDetector().detect(words: words("你好。", from: 2), duration: 5)
        XCTAssertEqual(cuts.filter { $0.kind == .pause }.count, 2)
        XCTAssertEqual(cuts.first!.sourceStart, 0.1, accuracy: 0.001)
        XCTAssertEqual(cuts.last!.sourceEnd, 4.9, accuracy: 0.001)
    }
    func testNativeSubtitleSequence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try SubtitleRenderer.makeSequence(
            cues: [SubtitleCue(start: 0.5, end: 1.5, text: "你好世界")], style: SubtitleStyle(), width: 640, height: 360,
            duration: 2, directory: directory, cancellation: CancellationToken())
        let script = try String(contentsOf: path)
        XCTAssertTrue(script.contains("duration 0.500000"))
        XCTAssertTrue(script.hasSuffix("file 'blank.png'\noption framerate 1000\n"))
        XCTAssertGreaterThan((try Data(contentsOf: directory.appendingPathComponent("cue-0.png"))).count, 1000)
    }
}
