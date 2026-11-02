import XCTest

@testable import ChuangCutCore

final class ProjectPackageTests: XCTestCase {
    func testProjectRoundTripWithDecisionsAndSubtitleEdits() throws {
        let words = [
            Word(text: "你好", start: 0.1, end: 0.4),
            Word(text: "世界", start: 0.5, end: 0.9),
            Word(text: "嗯", start: 1.0, end: 1.2),
        ]
        let transcript = Transcript(segments: [
            Segment(start: 0.1, end: 1.2, text: "你好世界嗯", words: words)
        ])
        var edits = SubtitleEdits()
        edits.hiddenWords = [words[2].id]
        edits.startShifts = [words[0].id: -0.05]
        edits.endShifts = [words[1].id: 0.08]
        var project = Project(
            source: URL(fileURLWithPath: "/tmp/sample.mp4"),
            media: MediaInfo(duration: 10, width: 1920, height: 1080, bitrate: 4_000_000, hasAudio: true),
            transcript: transcript,
            candidates: [
                CutCandidate(kind: .pause, start: 2, end: 2.6, reason: "pause"),
                CutCandidate(kind: .filler, start: 1.0, end: 1.2, text: "嗯", reason: "filler"),
                CutCandidate(kind: .manual, start: 5, end: 6, text: "Removed clip", reason: "manual"),
            ],
            silences: [TimeRange(2, 2.6)]
        )
        project.splitPoints = [3.5, 7.0]
        project.subtitleEdits = edits
        project.decisions = [
            EditDecision(.cut, TimeRange(8, 9), reason: "talk-cut"),
            EditDecision(.keep, TimeRange(1.0, 1.2), reason: "keep filler"),
        ]
        project.media.hasVideo = true
        project.media.frameRate = 30

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(decoded.source, project.source)
        XCTAssertEqual(decoded.media.duration, 10)
        XCTAssertEqual(decoded.transcript?.words.map(\.text), ["你好", "世界", "嗯"])
        XCTAssertEqual(decoded.candidates.count, 3)
        XCTAssertEqual(decoded.candidates.map(\.kind), [.pause, .filler, .manual])
        XCTAssertEqual(decoded.splitPoints, [3.5, 7.0])
        XCTAssertEqual(decoded.subtitleEdits?.hiddenWords, edits.hiddenWords)
        XCTAssertEqual(decoded.subtitleEdits?.startShifts, edits.startShifts)
        XCTAssertEqual(decoded.subtitleEdits?.endShifts, edits.endShifts)
        XCTAssertEqual(decoded.decisions?.count, 2)
        XCTAssertEqual(decoded.decisions?[0].action, .cut)
        XCTAssertEqual(decoded.decisions?[1].action, .keep)
        XCTAssertEqual(decoded.decisions?[0].range, TimeRange(8, 9))
    }

    func testPackageSaveLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chuangcut-pkg-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let media = dir.appendingPathComponent("clip.mp4")
        try Data([0, 1, 2, 3]).write(to: media)

        var project = Project(
            source: media,
            media: MediaInfo(duration: 2, width: 640, height: 360, bitrate: 1, hasAudio: true),
            candidates: [CutCandidate(kind: .manual, start: 0.5, end: 1.0, reason: "manual")],
            silences: []
        )
        project.splitPoints = [1.2]
        var edits = SubtitleEdits()
        let wordID = UUID()
        edits.hiddenWords = [wordID]
        project.subtitleEdits = edits
        project.decisions = [EditDecision(.cut, TimeRange(0.5, 1.0), reason: "x")]

        let package = dir.appendingPathComponent("Demo.chuangcut")
        let state = ProjectPackage.State(
            playhead: 1.25, previewCuts: false, mediaPath: media.path, mediaBookmark: ProjectPackage.makeBookmark(for: media))
        try ProjectPackage.save(project: project, state: state, to: package)

        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("state.json").path))

        let loaded = try ProjectPackage.load(from: package)
        XCTAssertEqual(loaded.project.candidates.count, 1)
        XCTAssertEqual(loaded.project.splitPoints, [1.2])
        XCTAssertEqual(loaded.project.subtitleEdits?.hiddenWords, [wordID])
        XCTAssertEqual(loaded.project.decisions?.count, 1)
        XCTAssertEqual(loaded.state.playhead, 1.25)
        XCTAssertEqual(loaded.state.previewCuts, false)
        XCTAssertEqual(loaded.mediaURL.standardizedFileURL, media.standardizedFileURL)
    }
}
