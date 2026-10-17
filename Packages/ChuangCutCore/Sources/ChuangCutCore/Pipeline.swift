import Foundation
import CryptoKit

public struct Pipeline {
    public var tools: ToolPaths
    public init(tools: ToolPaths = ToolPaths()) { self.tools = tools }
    public static var cacheRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChuangCut/cache") }
    public static func cacheDirectory(for source: URL) throws -> URL {
        let metadata = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = source.standardizedFileURL.path + "|\(metadata.fileSize ?? 0)|\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = cacheRoot.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    public static func save(_ project: Project) throws { try JSONFile.write(project, to: cacheDirectory(for: project.source).appendingPathComponent("project.json")) }
    public static func restore(_ source: URL) throws -> Project? {
        let path = try cacheDirectory(for: source).appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        var project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: path))
        project.transcript?.normalizePunctuation()
        for i in project.candidates.indices { project.candidates[i].text = TextNormalization.cjkPunctuation(project.candidates[i].text) }
        return project
    }
    public func analyze(input: URL, model: URL, language: String = "zh", settings: DetectionSettings = DetectionSettings(), cancellation: CancellationToken = CancellationToken(), progress: @escaping (String, Double) -> Void = { _, _ in }) throws -> Project {
        let ffmpeg = FFmpegRunner(tools: tools), media = try ffmpeg.probe(input, cancellation: cancellation)
        guard media.hasAudio else { throw ChuangCutError.message("This video has no audio to transcribe") }
        let cache = try Self.cacheDirectory(for: input)
        let modelStat = try model.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "dtw-v2|\(language)|\(model.path)|\(modelStat.fileSize ?? 0)|\(modelStat.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let transcriptURL = cache.appendingPathComponent("transcript-\(hash).json")
        let transcript: Transcript
        if let data = try? Data(contentsOf: transcriptURL), let cached = try? JSONDecoder().decode(Transcript.self, from: data) { var normalized = cached; normalized.normalizePunctuation(); transcript = normalized; progress("Cached transcript", 0.75) }
        else {
            progress("Extracting audio", 0.02)
            let wav = cache.appendingPathComponent("audio.wav")
            try ffmpeg.extractAudio(input, to: wav, cancellation: cancellation)
            transcript = try WhisperRunner(tools: tools).transcribe(wav: wav, model: model, language: language, output: cache.appendingPathComponent("whisper-\(hash).json"), cancellation: cancellation) { progress("Transcribing", 0.1 + $0 * 0.65) }
            try JSONFile.write(transcript, to: transcriptURL)
        }
        try cancellation.check(); progress("Detecting cuts", 0.8)
        let silences = try ffmpeg.silence(input, threshold: settings.pauseThreshold, duration: media.duration, cancellation: cancellation)
        let cuts = CutDetector(settings: settings).detect(words: transcript.words, duration: media.duration, silences: silences)
        let project = Project(source: input, media: media, transcript: transcript, candidates: cuts, silences: silences)
        try Self.save(project); progress("Ready", 1); return project
    }
}
