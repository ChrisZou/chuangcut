import Foundation

public enum VideoQuality: String, CaseIterable, Codable, Sendable { case compact, balanced, high, software }
public struct ExportOptions: Sendable {
    public var quality: VideoQuality = .balanced
    public var includeSRT = true
    public var burnSubtitles = false
    public var style = SubtitleStyle()
    public init() {}
}
public struct FFmpegRunner {
    public var tools: ToolPaths
    public init(tools: ToolPaths = ToolPaths()) { self.tools = tools }
    public func probe(_ input: URL, cancellation: CancellationToken = CancellationToken()) throws -> MediaInfo {
        let result = try ProcessRunner.run(tools.ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", input.path], cancellation: cancellation)
        guard let root = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any], let streams = root["streams"] as? [[String: Any]], let video = streams.first(where: { $0["codec_type"] as? String == "video" }) else { throw ChuangCutError.message("No video stream found") }
        let format = root["format"] as? [String: Any] ?? [:]
        let duration = Double(format["duration"] as? String ?? "0") ?? 0
        guard duration > 0 else { throw ChuangCutError.message("Video duration is unavailable") }
        return MediaInfo(duration: duration, width: video["width"] as? Int ?? 1280, height: video["height"] as? Int ?? 720, bitrate: Int(video["bit_rate"] as? String ?? format["bit_rate"] as? String ?? "4000000") ?? 4_000_000, hasAudio: streams.contains { $0["codec_type"] as? String == "audio" })
    }
    public func extractAudio(_ input: URL, to output: URL, cancellation: CancellationToken) throws {
        _ = try ProcessRunner.run(tools.ffmpeg, ["-y", "-v", "error", "-i", input.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", output.path], cancellation: cancellation)
    }
    public func silence(_ input: URL, threshold: Double, duration: Double, cancellation: CancellationToken) throws -> [TimeRange] {
        let result = try ProcessRunner.run(tools.ffmpeg, ["-hide_banner", "-i", input.path, "-vn", "-af", "silencedetect=noise=-35dB:d=\(max(0.1, threshold))", "-f", "null", "-"], cancellation: cancellation)
        return Self.parseSilences(result.stderr, duration: duration)
    }
    public static func parseSilences(_ log: String, duration: Double) -> [TimeRange] {
        let regex = try! NSRegularExpression(pattern: #"silence_(start|end):\s*([\d.]+)"#)
        let ns = log as NSString; var start: Double?; var result: [TimeRange] = []
        for match in regex.matches(in: log, range: NSRange(location: 0, length: ns.length)) {
            let type = ns.substring(with: match.range(at: 1)), value = Double(ns.substring(with: match.range(at: 2))) ?? 0
            if type == "start" { start = value } else { result.append(TimeRange(start ?? 0, min(duration, value))); start = nil }
        }
        if let start { result.append(TimeRange(start, duration)) }; return result
    }
    public func waveform(_ input: URL, buckets: Int = 3000, cancellation: CancellationToken) throws -> [Float] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("chuangcut-wave-\(UUID()).pcm")
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try ProcessRunner.run(tools.ffmpeg, ["-y", "-v", "error", "-i", input.path, "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", temp.path], cancellation: cancellation)
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        let count = data.count / 2, strideSize = max(1, count / max(1, buckets))
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var peaks: [Float] = []; var peak: Float = 0
            for i in 0..<count {
                peak = max(peak, abs(Float(Int16(littleEndian: samples[i]))) / 32768)
                if (i + 1) % strideSize == 0 { peaks.append(peak); peak = 0 }
            }
            if count % strideSize != 0 { peaks.append(peak) }; return peaks
        }
    }
    /// One encoding pass: trim/atrim, concatenate, then optionally overlay native subtitle PNGs.
    public func export(project: Project, to output: URL, options: ExportOptions, cancellation: CancellationToken, progress: @escaping (Double) -> Void) throws {
        let mapper = project.mapper, ranges = mapper.keptRanges
        guard mapper.editedDuration > 0.02 else { throw ChuangCutError.message("All media is cut. Disable a cut before exporting.") }
        guard output.standardizedFileURL != project.source.standardizedFileURL else { throw ChuangCutError.message("Choose an output different from the source video.") }
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".chuangcut-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let partial = staging.appendingPathComponent("output.mp4")
        let builder = SubtitleBuilder(style: options.style)
        let cues = builder.build(words: project.transcript?.words ?? [], mapper: mapper, fillers: project.candidates.filter { $0.kind == .filler })
        var args = ["-y", "-hide_banner", "-i", project.source.path]
        var filters: [String] = []
        if options.burnSubtitles {
            let sequence = try SubtitleRenderer.makeSequence(cues: cues, style: options.style, width: project.media.width, height: project.media.height, duration: mapper.editedDuration, directory: staging.appendingPathComponent("subtitles"), cancellation: cancellation)
            args += ["-f", "concat", "-safe", "0", "-i", sequence.path]
        }
        if !project.media.hasAudio { args += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"] }
        let audioInput = project.media.hasAudio ? "0:a:0" : (options.burnSubtitles ? "2:a:0" : "1:a:0")
        // Explicit split/asplit makes reuse of the same input deterministic for many kept ranges.
        filters.append("[0:v:0]split=\(ranges.count)" + ranges.indices.map { "[vin\($0)]" }.joined())
        filters.append("[\(audioInput)]asplit=\(ranges.count)" + ranges.indices.map { "[ain\($0)]" }.joined())
        for (i, range) in ranges.enumerated() {
            filters.append("[vin\(i)]trim=start=\(range.start):end=\(range.end),setpts=PTS-STARTPTS[v\(i)]")
            filters.append("[ain\(i)]atrim=start=\(range.start):end=\(range.end),asetpts=PTS-STARTPTS[a\(i)]")
        }
        filters.append(ranges.indices.map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(ranges.count):v=1:a=1[cutv][aout]")
        if options.burnSubtitles {
            filters.append("[1:v:0]format=rgba,setpts=PTS-STARTPTS[sub]")
            filters.append("[cutv][sub]overlay=0:0:eof_action=pass:format=auto,format=yuv420p[vout]")
        } else { filters.append("[cutv]format=yuv420p[vout]") }
        // Keep a diagnostic graph in staging. No user text enters the filter graph.
        let graph = staging.appendingPathComponent("filters.txt")
        try filters.joined(separator: ";\n").write(to: graph, atomically: true, encoding: .utf8)
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[vout]", "-map", "[aout]"]
        if options.quality == .software { args += ["-c:v", "libx264", "-crf", "20", "-preset", "medium"] }
        else {
            let multiplier = options.quality == .compact ? 0.6 : options.quality == .high ? 1.5 : 1.0
            let bitrate = max(1_500_000, min(40_000_000, Int(Double(project.media.bitrate) * multiplier)))
            args += ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)"]
        }
        args += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", "\(mapper.editedDuration)", "-progress", "pipe:1", "-nostats", partial.path]
        _ = try ProcessRunner.run(tools.ffmpeg, args, cancellation: cancellation, stdout: { line in
            if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                let value = Double(line.split(separator: "=").last ?? "0") ?? 0
                progress(min(0.99, value / 1_000_000 / mapper.editedDuration))
            }
        })
        try cancellation.check()
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: partial) }
        else { try FileManager.default.moveItem(at: partial, to: output) }
        let base = output.deletingPathExtension()
        if options.includeSRT { try builder.srt(cues).write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8) }
        try builder.ass(cues, width: project.media.width, height: project.media.height).write(to: base.appendingPathExtension("ass"), atomically: true, encoding: .utf8)
        progress(1)
    }
}
