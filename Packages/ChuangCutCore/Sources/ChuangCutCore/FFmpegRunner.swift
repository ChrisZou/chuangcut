import Accelerate
import Foundation

public enum VideoQuality: String, CaseIterable, Codable, Sendable { case compact, balanced, high, software }
public struct ExportOptions: Sendable {
    public var quality: VideoQuality = .balanced
    public var includeSRT = true
    /// A soft subtitle track (mov_text) inside the MP4, which players can show or hide.
    public var subtitleTrack = true
    public var burnSubtitles = false
    public var style = SubtitleStyle()
    public init() {}
}
public struct FFmpegRunner {
    public var tools: ToolPaths
    public init(tools: ToolPaths = ToolPaths()) { self.tools = tools }
    public func probe(_ input: URL, cancellation: CancellationToken = CancellationToken()) throws -> MediaInfo {
        let result = try ProcessRunner.run(
            tools.ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", input.path],
            cancellation: cancellation)
        return try Self.mediaInfo(probeJSON: result.stdout)
    }
    public static func mediaInfo(probeJSON: Data) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: probeJSON) as? [String: Any],
            let streams = root["streams"] as? [[String: Any]],
            let video = streams.first(where: { $0["codec_type"] as? String == "video" })
        else { throw ChuangCutError.message("No video stream found") }
        let format = root["format"] as? [String: Any] ?? [:]
        let duration = Double(format["duration"] as? String ?? "0") ?? 0
        guard duration > 0 else { throw ChuangCutError.message("Video duration is unavailable") }
        let fraction = (video["avg_frame_rate"] as? String ?? "0/1").split(separator: "/").compactMap { Double($0) }
        let fps = fraction.count == 2 && fraction[1] > 0 ? fraction[0] / fraction[1] : 0
        // Phones store portrait video as landscape pixels plus a display rotation. ffmpeg's filters
        // autorotate, so subtitles, previews and the player must all use the displayed size.
        var width = video["width"] as? Int ?? 1280
        var height = video["height"] as? Int ?? 720
        if Int(displayRotation(video).magnitude) % 180 == 90 { swap(&width, &height) }
        return MediaInfo(
            duration: duration, width: width, height: height,
            bitrate: Int(video["bit_rate"] as? String ?? format["bit_rate"] as? String ?? "4000000") ?? 4_000_000,
            hasAudio: streams.contains { $0["codec_type"] as? String == "audio" }, frameRate: fps)
    }
    static func displayRotation(_ stream: [String: Any]) -> Double {
        let sideData = stream["side_data_list"] as? [[String: Any]] ?? []
        if let rotation = sideData.lazy.compactMap({ ($0["rotation"] as? NSNumber)?.doubleValue }).first {
            return rotation.rounded()
        }
        let tags = stream["tags"] as? [String: Any] ?? [:]
        return Double(tags["rotate"] as? String ?? "0") ?? 0
    }
    public func extractAudio(_ input: URL, to output: URL, cancellation: CancellationToken) throws {
        _ = try ProcessRunner.run(
            tools.ffmpeg,
            [
                "-y", "-v", "error", "-i", input.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                output.path,
            ], cancellation: cancellation)
    }
    /// Mono 16 kHz MP3 for uploading: about 22 MB per hour, a fifth of the WAV.
    public func extractSpeech(_ input: URL, to output: URL, cancellation: CancellationToken) throws {
        _ = try ProcessRunner.run(
            tools.ffmpeg,
            ["-y", "-v", "error", "-i", input.path, "-vn", "-ar", "16000", "-ac", "1", "-b:a", "48k", output.path],
            cancellation: cancellation)
    }
    public func silence(_ input: URL, threshold: Double, duration: Double, cancellation: CancellationToken) throws
        -> [TimeRange]
    {
        let result = try ProcessRunner.run(
            tools.ffmpeg,
            [
                "-hide_banner", "-i", input.path, "-vn", "-af", "silencedetect=noise=-35dB:d=\(max(0.1, threshold))",
                "-f", "null", "-",
            ], cancellation: cancellation)
        return Self.parseSilences(result.stderr, duration: duration)
    }
    public static func parseSilences(_ log: String, duration: Double) -> [TimeRange] {
        let regex = try! NSRegularExpression(pattern: #"silence_(start|end):\s*([\d.]+)"#)
        let ns = log as NSString
        var start: Double?
        var result: [TimeRange] = []
        for match in regex.matches(in: log, range: NSRange(location: 0, length: ns.length)) {
            let type = ns.substring(with: match.range(at: 1))
            let value = Double(ns.substring(with: match.range(at: 2))) ?? 0
            if type == "start" {
                start = value
            } else {
                result.append(TimeRange(start ?? 0, min(duration, value)))
                start = nil
            }
        }
        if let start { result.append(TimeRange(start, duration)) }
        return result
    }
    /// Peaks at a fixed time resolution, so long videos keep word-level detail on the timeline.
    public func waveform(_ input: URL, peaksPerSecond: Int = 100, cancellation: CancellationToken) throws -> [Float] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("chuangcut-wave-\(UUID()).pcm")
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try ProcessRunner.run(
            tools.ffmpeg,
            ["-y", "-v", "error", "-i", input.path, "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", temp.path],
            cancellation: cancellation)
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        let count = data.count / 2
        let strideSize = max(1, 8000 / max(1, peaksPerSecond))
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var peaks: [Float] = []
            var peak: Float = 0
            for i in 0..<count {
                peak = max(peak, abs(Float(Int16(littleEndian: samples[i]))) / 32768)
                if (i + 1) % strideSize == 0 {
                    peaks.append(peak)
                    peak = 0
                }
            }
            if count % strideSize != 0 { peaks.append(peak) }
            return peaks
        }
    }
    /// RMS level per 10 ms frame. Decoding the audio takes under a second even for half an hour.
    public func loudness(_ input: URL, cancellation: CancellationToken) throws -> Loudness {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("chuangcut-level-\(UUID()).pcm")
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try ProcessRunner.run(
            tools.ffmpeg,
            ["-y", "-v", "error", "-i", input.path, "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", temp.path],
            cancellation: cancellation)
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        let size = Int(8000 * Loudness.frame)
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var values = [Float](repeating: 0, count: samples.count)
            vDSP_vflt16(samples.baseAddress!, 1, &values, 1, vDSP_Length(samples.count))
            var levels: [Float] = []
            levels.reserveCapacity(samples.count / size + 1)
            values.withUnsafeBufferPointer { buffer in
                var start = 0
                while start < buffer.count {
                    let count = min(size, buffer.count - start)
                    var meanSquare: Float = 0
                    vDSP_measqv(buffer.baseAddress! + start, 1, &meanSquare, vDSP_Length(count))
                    levels.append(10 * log10(meanSquare / (32768 * 32768) + 1e-10))
                    start += count
                }
            }
            return Loudness(levels: levels)
        }
    }
    /// ISO 639-2 code for the MP4 subtitle track, so players label it.
    static func subtitleLanguage(_ code: String?) -> String {
        [
            "zh": "chi", "en": "eng", "ja": "jpn", "ko": "kor", "fr": "fre", "de": "ger", "es": "spa",
        ][code ?? ""] ?? "und"
    }
    /// One encoding pass: trim/atrim, concatenate, then optionally overlay native subtitle PNGs.
    public func export(
        project: Project, to output: URL, options: ExportOptions, cancellation: CancellationToken,
        progress: @escaping (Double) -> Void
    ) throws {
        let mapper = project.mapper
        let ranges = mapper.keptRanges
        guard mapper.editedDuration > 0.02 else {
            throw ChuangCutError.message("All media is cut. Disable a cut before exporting.")
        }
        guard output.standardizedFileURL != project.source.standardizedFileURL else {
            throw ChuangCutError.message("Choose an output different from the source video.")
        }
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".chuangcut-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let partial = staging.appendingPathComponent("output.mp4")
        let builder = SubtitleBuilder(style: options.style)
        let cues = builder.build(project: project, mapper: mapper)
        var args = ["-y", "-hide_banner", "-i", project.source.path]
        var filters: [String] = []
        if options.burnSubtitles {
            let sequence = try SubtitleRenderer.makeSequence(
                cues: cues, style: options.style, width: project.media.width, height: project.media.height,
                duration: mapper.editedDuration, directory: staging.appendingPathComponent("subtitles"),
                cancellation: cancellation)
            args += ["-f", "concat", "-safe", "0", "-i", sequence.path]
        }
        if !project.media.hasAudio { args += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"] }
        let audioInput = project.media.hasAudio ? "0:a:0" : (options.burnSubtitles ? "2:a:0" : "1:a:0")
        let subtitleInput = 1 + (options.burnSubtitles ? 1 : 0) + (project.media.hasAudio ? 0 : 1)
        let subtitleTrack = options.subtitleTrack && !cues.isEmpty
        if subtitleTrack {
            let srt = staging.appendingPathComponent("track.srt")
            try builder.srt(cues).write(to: srt, atomically: true, encoding: .utf8)
            args += ["-f", "srt", "-i", srt.path]
        }
        // Explicit split/asplit makes reuse of the same input deterministic for many kept ranges.
        filters.append("[0:v:0]split=\(ranges.count)" + ranges.indices.map { "[vin\($0)]" }.joined())
        filters.append("[\(audioInput)]asplit=\(ranges.count)" + ranges.indices.map { "[ain\($0)]" }.joined())
        for (i, range) in ranges.enumerated() {
            filters.append("[vin\(i)]trim=start=\(range.start):end=\(range.end),setpts=PTS-STARTPTS[v\(i)]")
            filters.append("[ain\(i)]atrim=start=\(range.start):end=\(range.end),asetpts=PTS-STARTPTS[a\(i)]")
        }
        filters.append(
            ranges.indices.map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(ranges.count):v=1:a=1[cutv][aout]")
        if options.burnSubtitles {
            filters.append("[1:v:0]format=rgba,setpts=PTS-STARTPTS[sub]")
            filters.append("[cutv][sub]overlay=0:0:eof_action=pass:format=auto,format=yuv420p[vout]")
        } else {
            filters.append("[cutv]format=yuv420p[vout]")
        }
        // Keep a diagnostic graph in staging. No user text enters the filter graph.
        let graph = staging.appendingPathComponent("filters.txt")
        try filters.joined(separator: ";\n").write(to: graph, atomically: true, encoding: .utf8)
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[vout]", "-map", "[aout]"]
        if subtitleTrack {
            args += [
                "-map", "\(subtitleInput):s:0", "-c:s", "mov_text", "-metadata:s:s:0",
                "language=\(Self.subtitleLanguage(project.transcript?.language))", "-disposition:s:0", "default",
            ]
        }
        if options.quality == .software {
            args += ["-c:v", "libx264", "-crf", "20", "-preset", "medium"]
        } else {
            let multiplier = options.quality == .compact ? 0.6 : options.quality == .high ? 1.5 : 1.0
            let bitrate = max(1_500_000, min(40_000_000, Int(Double(project.media.bitrate) * multiplier)))
            args += ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)"]
        }
        args += [
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", "\(mapper.editedDuration)", "-progress",
            "pipe:1", "-nostats", partial.path,
        ]
        _ = try ProcessRunner.run(
            tools.ffmpeg, args, cancellation: cancellation,
            stdout: { line in
                if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                    let value = Double(line.split(separator: "=").last ?? "0") ?? 0
                    progress(min(0.99, value / 1_000_000 / mapper.editedDuration))
                }
            })
        try cancellation.check()
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: output)
        }
        let base = output.deletingPathExtension()
        if options.includeSRT {
            try builder.srt(cues).write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        }
        try builder.ass(cues, width: project.media.width, height: project.media.height).write(
            to: base.appendingPathExtension("ass"), atomically: true, encoding: .utf8)
        progress(1)
    }
}
