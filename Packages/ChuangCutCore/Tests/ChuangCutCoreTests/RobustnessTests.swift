import XCTest

@testable import ChuangCutCore

/// Real-world cases beyond the synthetic fixture: everyday Chinese that resembles fillers or
/// retakes, phone footage, imprecise Whisper boundaries, and long recordings.
final class RobustnessTests: XCTestCase {
    func words(_ sentences: [String], gap: Double = 0.3) -> [Word] {
        var time = 0.0
        var result: [Word] = []
        for sentence in sentences {
            for character in sentence {
                result.append(Word(text: String(character), start: time, end: time + 0.2))
                time += 0.2
            }
            time += gap
        }
        return result
    }
    func speechCuts(_ sentences: [String], gap: Double = 0.3) -> [String] {
        let input = words(sentences, gap: gap)
        return CutDetector().detect(words: input, duration: input.last!.end + 0.3).filter { $0.kind != .pause }
            .map { "\($0.kind.rawValue):\($0.text)" }
    }

    func testHesitationCharacterInsideWordsIsKept() {
        XCTAssertEqual(speechCuts(["Claude的免费额度用完了，", "这个金额不算高。"]), [])
        XCTAssertEqual(speechCuts(["名额有限，", "还有额外的功能。"]), [])
        XCTAssertEqual(speechCuts(["额我觉得可以。"]), ["filler:额"])
    }
    func testFillersAreCutOnlyAtSentenceEdges() {
        XCTAssertEqual(speechCuts(["我们额先看一下。"]), [])
        XCTAssertEqual(speechCuts(["这个功能，嗯，那个，其实挺好用的。"]), [])
        XCTAssertEqual(speechCuts(["嗯，那个，今天我们来聊。"]), ["filler:嗯，", "filler:那个，"])
        XCTAssertEqual(speechCuts(["今天就到这里，嗯。"]), ["filler:嗯。"])
        XCTAssertEqual(speechCuts(["嗯我们开始吧嗯"]), ["filler:嗯", "filler:嗯"])
        // A pause long enough to be cut ends a sentence, as does a Whisper segment without punctuation.
        XCTAssertEqual(speechCuts(["这个功能，", "嗯，其实挺好用的。"], gap: 1), ["filler:嗯，"])
        let input = words(["我们开始吧", "嗯先看第一个"], gap: 0.1)
        let detector = CutDetector()
        XCTAssertEqual(detector.detect(words: input, duration: 4).filter { $0.kind == .filler }.count, 0)
        let cuts = detector.detect(words: input, duration: 4, sentenceEnds: [input[4].id])
        XCTAssertEqual(cuts.filter { $0.kind == .filler }.map(\.text), ["嗯"])
    }
    func testReduplicationAndLaughterAreNotStutters() {
        XCTAssertEqual(speechCuts(["我们来体验体验这个功能。", "大家可以研究研究。"]), [])
        XCTAssertEqual(speechCuts(["哈哈哈哈，太好笑了。"]), [])
        XCTAssertEqual(speechCuts(["我们我们开始吧，", "这个这个功能很好。"]), ["retake:我们", "retake:这个"])
    }
    func testParallelListItemsAreNotRetakes() {
        XCTAssertEqual(speechCuts(["第一个优点是速度快，", "第二个优点是速度快，", "第三个优点是价格低。"]), [])
        XCTAssertEqual(speechCuts(["首先打开设置页面，", "其次打开设置页面。"]), [])
        // Rewording that drops a numeral on one side only is still a retake.
        XCTAssertEqual(speechCuts(["今天我们来聊一聊视频剪辑。", "今天我们来聊视频剪辑。"]), ["retake:今天我们来聊一聊视频剪辑。"])
        XCTAssertEqual(speechCuts(["第一个优点是", "第一个优点是速度快。"], gap: 1), ["retake:第一个优点是"])
    }

    func keptText(_ sentences: [String], gap: Double = 0.3) -> String {
        let input = words(sentences, gap: gap)
        let duration = input.last!.end + 0.3
        let mapper = TimelineMapper(duration: duration, cuts: CutDetector().detect(words: input, duration: duration))
        return input.filter { !mapper.removes($0) }.map(\.text).joined()
    }
    func testOnlyTheLastTakeIsKept() {
        // Several attempts at a two-sentence opening, restarted from different points.
        XCTAssertEqual(
            keptText(
                [
                    "我们都知道AI已经", "我们都知道AI", "我们都知道AI已经造成了很多人的失业了，", "所以", "所以为了报仇，",
                    "我们决定以其人之道还治其人之身。", "我们都知道AI已经造成了很多人的失业了，", "所以为了",
                    "我们都知道AI已经造成了很多人的失业了，", "所以为了报仇，", "我们决定以其人之道还治其人之身。",
                ], gap: 0.8),
            "我们都知道AI已经造成了很多人的失业了，所以为了报仇，我们决定以其人之道还治其人之身。")
        // A take split by a pause is cut whole, and a slightly reworded later take still counts.
        XCTAssertEqual(
            keptText(["看过几", "千份简历的经验，", "全部融入在这个工作台中了。", "看过几千份简历的经验，", "全部融入到了这个工作台中。"], gap: 0.8),
            "看过几千份简历的经验，全部融入到了这个工作台中。")
        XCTAssertEqual(
            keptText(["相信这个视频对你一定有巨大的帮助。", "如果你正在找工作，", "相信这个视频一定对你有巨大的帮助。"]),
            "如果你正在找工作，相信这个视频一定对你有巨大的帮助。")
    }
    func testDistinctSentencesAreNotRetakes() {
        XCTAssertEqual(speechCuts(["我们先打开设置页面，", "然后点击模型列表。", "我们再看看价格怎么样。"]), [])
        XCTAssertEqual(speechCuts(["所以，", "我们决定自己做一个。", "所以这个工具就诞生了。"]), [])
        // The same sentence a minute later is new content, not a retake.
        XCTAssertEqual(speechCuts(["这个功能非常好用。", "这个功能非常好用。"], gap: 50), [])
    }
    func testRetakeCutStopsAtTheNextTakesFirstWord() {
        // Whisper put 里 of 里面 before the pause the speaker made ahead of it.
        var input = words(["都用AI帮你做"])
        input.append(Word(text: "里", start: 1.4, end: 1.5))
        input += words(["面包含了大量细节"]).map { Word(text: $0.text, start: $0.start + 2.3, end: $0.end + 2.3) }
        input += words(["都用AI帮你做了准备"]).map { Word(text: $0.text, start: $0.start + 4.5, end: $0.end + 4.5) }
        XCTAssertTrue(CutDetector.pauseSplitsWord([input[7]], input[8...]))
        XCTAssertFalse(CutDetector.pauseSplitsWord(Array(input[...6]), input[7...]))
        let cuts = CutDetector().detect(
            words: input, duration: 7, silences: [TimeRange(1.5, 2.3)], sentenceEnds: [input[6].id])
        let mapper = TimelineMapper(duration: 7, cuts: cuts)
        XCTAssertEqual(input.filter { !mapper.removes($0) }.map(\.text).joined(), "里面包含了大量细节都用AI帮你做了准备")
    }
    func testVerbatimRestartsKeepOnlyTheLastTake() {
        // Doubao writes down the restarts Whisper leaves out, often several within one clause.
        XCTAssertEqual(
            keptText(["如果如果你正在搞，", "如果你正在找，", "如果你正在找工作，", "相信这个视频一定对你有巨大的帮助。"]),
            "如果你正在找工作，相信这个视频一定对你有巨大的帮助。")
        XCTAssertEqual(keptText(["里面里面包里面包含了大量细节。"]), "里面包含了大量细节。")
        XCTAssertEqual(keptText(["所以我们都知道A我们都知道AI已经来了。"]), "所以我们都知道AI已经来了。")
        XCTAssertEqual(keptText(["我们一步一步来。"]), "我们一步一步来。")
    }
    func testWordsGluedToARestartGoWithTheAbandonedTake() {
        // 所以为了 continues the take before the pause; 我们都知道… starts over right after it.
        XCTAssertEqual(
            keptText(["我们都知道AI已经造成了失业，所以为了", "所以为了我们都知道AI已经造成了失业，", "所以为了报仇。"], gap: 0.8),
            "我们都知道AI已经造成了失业，所以为了报仇。")
        // A connective added in the final take is kept.
        XCTAssertEqual(keptText(["我们都知道AI很厉害。", "所以我们都知道AI很厉害。"], gap: 0.8), "所以我们都知道AI很厉害。")
    }
    func testRewordedTakeIsAnEarlierTake() {
        XCTAssertEqual(
            keptText(["里面有大量，", "你意思不，", "里面包含了大量你意想不到的细节。"], gap: 0.8), "里面包含了大量你意想不到的细节。")
        // Sentences that only share an opening and a few words stay.
        XCTAssertEqual(speechCuts(["我们先打开设置页面，", "我们再打开模型页面。"]), [])
    }
    func testKeptClipsStartAsSpeechBeginsAndEndAsItFades() {
        // Room tone at -70 dB; one word is audible from 2.00 s (soft attack from 1.97 s) to 2.50 s, and the ASR
        // puts it at 2.05–2.45. Pauses on both sides are cut.
        var levels = [Float](repeating: -70, count: 400)
        for i in 197..<200 { levels[i] = -55 }
        for i in 200..<250 { levels[i] = -20 }
        let word = Word(text: "好", start: 2.05, end: 2.45)
        let cuts = CutDetector().detect(
            words: [word], duration: 4, silences: [TimeRange(0, 1.97), TimeRange(2.5, 4)],
            loudness: Loudness(levels: levels))
        let kept = TimelineMapper(duration: 4, cuts: cuts).keptRanges
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].start, 1.94, accuracy: 0.001)
        XCTAssertEqual(kept[0].end, 2.60, accuracy: 0.001)
    }
    func testNoWordlessSliverIsLeftBetweenCuts() {
        // A breath between the first take and the pause has no words; it goes with the take.
        let input =
            words(["今天我们来聊。"]) + words(["今天我们来聊剪辑。"]).map { Word(text: $0.text, start: $0.start + 3, end: $0.end + 3) }
        let cuts = CutDetector().detect(words: input, duration: 5.5, silences: [TimeRange(2, 3)])
        let ranges = TimelineMapper(duration: 5.5, cuts: cuts).cutRanges
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(ranges[0].end, 2.9, accuracy: 0.001)
        // A burp between two pauses has no words either.
        let burp = CutDetector().detect(
            words: words(["好的"]), duration: 6, silences: [TimeRange(1, 2), TimeRange(2.3, 6)])
        XCTAssertEqual(TimelineMapper(duration: 6, cuts: burp).keptRanges.count, 1)
    }

    func testRotatedPhoneVideoUsesDisplaySize() throws {
        func info(_ stream: String) throws -> MediaInfo {
            let json =
                #"{"format":{"duration":"10.0","bit_rate":"5000000"},"streams":[{"codec_type":"video","width":1920,"height":1080,"avg_frame_rate":"30/1",\#(stream)},{"codec_type":"audio"}]}"#
            return try FFmpegRunner.mediaInfo(probeJSON: Data(json.utf8))
        }
        let rotated = try info(#""side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}]"#)
        XCTAssertEqual([rotated.width, rotated.height], [1080, 1920])
        let legacy = try info(#""tags":{"rotate":"270"}"#)
        XCTAssertEqual([legacy.width, legacy.height], [1080, 1920])
        let upsideDown = try info(#""side_data_list":[{"rotation":180}]"#)
        XCTAssertEqual([upsideDown.width, upsideDown.height], [1920, 1080])
    }

    /// Whisper reported 今 at 2.72–3.83 although speech resumed at 4.56, and 辑 inside the next pause.
    func testWordSpanningASilenceMovesToItsLongerSide() {
        let words = [Word(text: "我", start: 31.88, end: 32.86), Word(text: "们", start: 32.86, end: 33.1)]
        let aligned = Transcript.align(words, gaps: [TimeRange(31.94, 32.63)])
        XCTAssertEqual(aligned[0].start, 32.63, accuracy: 1e-9)
        XCTAssertEqual(aligned[0].end, 32.86, accuracy: 1e-9)
    }
    func testWordsAreAlignedToAcousticSilence() {
        let segment = Segment(
            start: 2.72, end: 7.22, text: "今天我们剪辑",
            words: [
                Word(text: "今", start: 2.72, end: 3.83), Word(text: "天", start: 3.83, end: 4.95),
                Word(text: "我", start: 4.95, end: 5.13), Word(text: "们", start: 5.13, end: 6.75),
                Word(text: "剪", start: 6.75, end: 6.96), Word(text: "辑", start: 6.96, end: 7.22),
            ])
        let silences = [TimeRange(2.71, 4.56), TimeRange(6.88, 8.22)]
        let aligned = Transcript(segments: [segment]).aligned(to: silences).words
        XCTAssertEqual(aligned.map(\.start), [4.56, 4.755, 4.95, 5.13, 6.75, 6.815], accuracy: 1e-9)
        XCTAssertEqual(aligned.map(\.end), [4.755, 4.95, 5.13, 6.75, 6.815, 6.88], accuracy: 1e-9)

        // With the pause cuts applied, every spoken word survives into the subtitles.
        let cuts = silences.map { CutCandidate(kind: .pause, start: $0.start + 0.1, end: $0.end - 0.1, reason: "") }
        let mapper = TimelineMapper(duration: 9, cuts: cuts)
        XCTAssertEqual(SubtitleBuilder().build(words: aligned, mapper: mapper).map(\.text).joined(), "今天我们剪辑")
        XCTAssertNotEqual(
            SubtitleBuilder().build(words: segment.words, mapper: mapper).map(\.text).joined(), "今天我们剪辑")
    }
    /// Whisper sometimes emits no sentence-final punctuation for Chinese at all.
    func testSegmentsEndSubtitleSentencesWithoutPunctuation() {
        let first = words(["大家好欢迎来到我的频道"])
        let second = words(["今天我们来聊视频剪辑"]).map { Word(text: $0.text, start: $0.start + 2.3, end: $0.end + 2.3) }
        let transcript = Transcript(segments: [
            Segment(start: 0, end: 2.2, text: "大家好欢迎来到我的频道", words: first),
            Segment(start: 2.3, end: 4.3, text: "今天我们来聊视频剪辑", words: second),
        ])
        let cues = SubtitleBuilder().build(transcript: transcript, mapper: TimelineMapper(duration: 5, cuts: []))
        XCTAssertEqual(cues.map(\.text), ["大家好欢迎来到我的频道", "今天我们来聊视频剪辑"])
    }
    func testWholeSegmentInsideSilenceIsLeftAlone() {
        let words = [Word(text: "嗯", start: 1, end: 1.5), Word(text: "啊", start: 1.5, end: 2)]
        let aligned = Transcript(segments: [Segment(start: 1, end: 2, text: "嗯啊", words: words)])
            .aligned(to: [TimeRange(0.5, 3)])
        XCTAssertEqual(aligned.words, words)
    }

    func testBatchCandidateLookupAndPreviewMatchFullComputation() {
        let input = words(["今天我们来聊视频剪辑，", "首先导入一段视频。", "然后自动识别停顿。"], gap: 0.8)
        var cuts = [
            CutCandidate(kind: .pause, start: 2.1, end: 2.8, reason: ""),
            CutCandidate(kind: .retake, start: 0.4, end: 1.3, reason: ""),
            CutCandidate(kind: .manual, start: 3.9, end: 4.6, reason: ""),
        ]
        cuts[2].enabled = false
        let mapper = TimelineMapper(duration: 10, cuts: cuts)
        XCTAssertEqual(
            mapper.candidates(for: input, cuts: cuts).map(\.?.id),
            input.map { mapper.candidate(for: $0, cuts: cuts)?.id })
        let all = SubtitleBuilder().build(words: input, mapper: mapper)
        XCTAssertEqual(SubtitleBuilder().build(words: input, mapper: mapper, maxCues: 1), Array(all.prefix(1)))
    }
    func testBatchPauseInsertionMatchesSingleLookup() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            // Unsorted, overlapping and zero-length words exercise the running-maximum search.
            var input: [Word] = []
            var time = 0.0
            for _ in 0..<Int.random(in: 0...40, using: &generator) {
                time += Double.random(in: -0.2...0.5, using: &generator)
                input.append(Word(text: "字", start: time, end: time + Double.random(in: 0...0.6, using: &generator)))
            }
            var cuts: [CutCandidate] = []
            for _ in 0..<Int.random(in: 0...8, using: &generator) {
                let start = Double.random(in: -1...(time + 1), using: &generator)
                var cut = CutCandidate(
                    kind: .pause, start: start, end: start + Double.random(in: 0.05...1.5, using: &generator),
                    reason: "")
                cut.enabled = Bool.random(using: &generator)
                cuts.append(cut)
            }
            let mapper = TimelineMapper(duration: time + 3, cuts: cuts)
            XCTAssertEqual(
                mapper.pauseInsertionIndices(cuts, words: input),
                cuts.map { mapper.pauseInsertionIndex($0, words: input) })
        }
    }
    /// A 30-minute talk without sentence-final punctuation used to take minutes to lay out.
    func testLongRecordingStaysInteractive() {
        var input: [Word] = []
        var cuts: [CutCandidate] = []
        var time = 0.0
        while time < 1800 {
            for _ in 0..<24 {
                input.append(Word(text: "字", start: time, end: time + 0.22))
                time += 0.22
            }
            input.append(Word(text: "，", start: time, end: time))
            cuts.append(CutCandidate(kind: .pause, start: time + 0.1, end: time + 0.7, reason: ""))
            time += 0.8
        }
        let mapper = TimelineMapper(duration: time, cuts: cuts)
        let started = Date()
        _ = mapper.candidates(for: input, cuts: cuts)
        _ = mapper.pauseInsertionIndices(cuts, words: input)
        XCTAssertFalse(SubtitleBuilder().build(words: input, mapper: mapper, maxCues: 1).isEmpty)
        XCTAssertGreaterThan(SubtitleBuilder().build(words: input, mapper: mapper).count, 400)
        // Generous bound for unoptimized test builds; the quadratic versions took far longer.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

private func XCTAssertEqual(
    _ lhs: [Double], _ rhs: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (a, b) in zip(lhs, rhs) { XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line) }
}
