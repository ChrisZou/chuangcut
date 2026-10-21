import CryptoKit
import Foundation

public enum TranscriptionEngine: Sendable {
    /// whisper.cpp with a local ggml model. Works offline, but drops restarts and repeated phrases.
    case whisper(model: URL)
    /// Doubao Seed-ASR in the cloud: verbatim, with per-character timestamps.
    case doubao(apiKey: String, hotwordTable: String?)
}

public struct Pipeline {
    public var tools: ToolPaths
    public init(tools: ToolPaths = ToolPaths()) { self.tools = tools }
    public static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/ChuangCut/cache")
    }
    public static func cacheDirectory(for source: URL) throws -> URL {
        let metadata = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key =
            source.standardizedFileURL.path
            + "|\(metadata.fileSize ?? 0)|\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = cacheRoot.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// Earlier versions kept Whisper's WAV input in every cache directory; remove those copies.
    public static func removeCachedAudio() {
        let directories =
            (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("audio.wav"))
        }
    }
    public static func save(_ project: Project) throws {
        try JSONFile.write(project, to: cacheDirectory(for: project.source).appendingPathComponent("project.json"))
    }
    public static func restore(_ source: URL) throws -> Project? {
        let path = try cacheDirectory(for: source).appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        var project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: path))
        project.transcript?.normalizePunctuation()
        for i in project.candidates.indices {
            project.candidates[i].text = TextNormalization.cjkPunctuation(project.candidates[i].text)
        }
        return project
    }
    public func analyze(
        input: URL, engine: TranscriptionEngine, language: String = "zh",
        settings: DetectionSettings = DetectionSettings(),
        cancellation: CancellationToken = CancellationToken(),
        progress: @escaping (String, Double) -> Void = { _, _ in }
    ) throws -> Project {
        let ffmpeg = FFmpegRunner(tools: tools)
        let media = try ffmpeg.probe(input, cancellation: cancellation)
        guard media.hasAudio else { throw ChuangCutError.message("This video has no audio to transcribe") }
        let cache = try Self.cacheDirectory(for: input)
        let key: String
        switch engine {
        case .whisper(let model):
            let modelStat = try model.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            key =
                "dtw-v2|\(language)|\(model.path)|\(modelStat.fileSize ?? 0)|\(modelStat.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        case .doubao(_, let hotwordTable): key = "doubao-flash-v1|\(hotwordTable ?? "")"
        }
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let transcriptURL = cache.appendingPathComponent("transcript-\(hash).json")
        let transcript: Transcript
        if let data = try? Data(contentsOf: transcriptURL),
            let cached = try? JSONDecoder().decode(Transcript.self, from: data)
        {
            var normalized = cached
            normalized.normalizePunctuation()
            transcript = normalized
            progress("Cached transcript", 0.75)
        } else {
            progress("Extracting audio", 0.02)
            switch engine {
            case .whisper(let model):
                // The 16 kHz WAV is only Whisper's input (~115 MB per hour), so it is not kept in the cache.
                let wav = FileManager.default.temporaryDirectory.appendingPathComponent("chuangcut-\(UUID()).wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                try ffmpeg.extractAudio(input, to: wav, cancellation: cancellation)
                transcript = try WhisperRunner(tools: tools).transcribe(
                    wav: wav, model: model, language: language,
                    output: cache.appendingPathComponent("whisper-\(hash).json"), cancellation: cancellation
                ) { progress("Transcribing", 0.1 + $0 * 0.65) }
            case .doubao(let apiKey, let hotwordTable):
                transcript = try DoubaoRunner(apiKey: apiKey, hotwordTable: hotwordTable, tools: tools).transcribe(
                    input: input, duration: media.duration, cancellation: cancellation
                ) { progress("Transcribing", 0.1 + $0 * 0.65) }
            }
            try JSONFile.write(transcript, to: transcriptURL)
        }
        try cancellation.check()
        progress("Detecting cuts", 0.8)
        let silences = try ffmpeg.silence(
            input, threshold: settings.pauseThreshold, duration: media.duration, cancellation: cancellation)
        let aligned = transcript.aligned(to: silences)
        let cuts = CutDetector(settings: settings).detect(
            words: aligned.words, duration: media.duration, silences: silences, sentenceEnds: aligned.sentenceEnds)
        let project = Project(source: input, media: media, transcript: aligned, candidates: cuts, silences: silences)
        try Self.save(project)
        progress("Ready", 1)
        return project
    }
}
