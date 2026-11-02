import ChuangCutCore
import Foundation

@main struct CLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let path = args.first, !path.hasPrefix("--") else {
                print(
                    "Usage: chuangcut-cli <input video or audio> --out <dir> [--model PATH | --engine doubao] [--lang zh|auto] [--pause 0.6] [--decisions FILE] [--burn | --no-export] [--trim INDEX:left|right:SECONDS]…"
                )
                return
            }
            func value(_ key: String) -> String? {
                guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            guard let out = value("--out") else { throw ChuangCutError.message("--out is required") }
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let destination = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            let engine: TranscriptionEngine
            if value("--engine") == "doubao" {
                // The key comes from the environment so it stays out of shell history.
                guard let key = ProcessInfo.processInfo.environment["DOUBAO_ASR_API_KEY"], !key.isEmpty else {
                    throw ChuangCutError.message("--engine doubao needs DOUBAO_ASR_API_KEY in the environment")
                }
                engine = .doubao(apiKey: key, hotwordTable: value("--hotword-table"))
            } else {
                let model =
                    value("--model").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    ?? ModelManager.discover().first
                guard let model else { throw ChuangCutError.message("No ggml model found. Pass --model PATH.") }
                engine = .whisper(model: model)
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var settings = DetectionSettings()
            if let pause = value("--pause") {
                guard let number = Double(pause), number >= 0.1 else {
                    throw ChuangCutError.message("--pause must be at least 0.1 seconds")
                }
                settings.pauseThreshold = number
            }
            let cancellation = CancellationToken()
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            for source in [interrupt, terminate] {
                source.setEventHandler { cancellation.cancel() }
                source.resume()
            }
            defer {
                interrupt.cancel()
                terminate.cancel()
            }
            switch engine {
            case .whisper(let model): print("Model: \(model.lastPathComponent)")
            case .doubao: print("Engine: Doubao Seed-ASR")
            }
            // The project is the one the app opens for this file: decisions, manual cuts, splits and subtitle
            // edits made earlier, here or in the app, carry over.
            let saved = try Pipeline.restore(source)
            let decisions = try value("--decisions").map {
                try JSONDecoder().decode(
                    [EditDecision].self,
                    from: Data(contentsOf: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)))
            }
            var project = try Pipeline().analyze(
                input: source, engine: engine, language: value("--lang") ?? "zh", settings: settings,
                decisions: decisions ?? saved?.decisions, cancellation: cancellation
            ) { stage, percent in
                if percent == 1 || percent == 0.02 || percent == 0.8 { print("\(stage) \(Int(percent * 100))%") }
            }
            func printSegments(_ label: String) {
                print(label)
                for (i, range) in project.mapper.keptRanges.enumerated() {
                    print(String(format: "  %d: %.3f–%.3f", i, range.start, range.end))
                }
            }
            if let saved {
                project.candidates = (project.candidates + saved.candidates.filter { $0.kind == .manual }).sorted {
                    $0.sourceStart < $1.sourceStart
                }
                project.splitPoints = saved.splitPoints
                project.subtitleEdits = saved.subtitleEdits
            }
            printSegments("Kept segments before trims:")
            for index in args.indices where args[index] == "--trim" {
                guard index + 1 < args.count else { throw ChuangCutError.message("--trim needs a value") }
                let trim = try TrimInstruction(args[index + 1])
                guard project.mapper.keptRanges.indices.contains(trim.segmentIndex) else {
                    throw ChuangCutError.message("Trim segment index is out of range")
                }
                project.candidates = TimelineEditor.trim(
                    duration: project.media.duration, segmentIndex: trim.segmentIndex, edge: trim.edge,
                    newSourceTime: trim.sourceTime, cuts: project.candidates)
            }
            printSegments("Kept segments after trims:")
            try Pipeline.save(project)
            try JSONFile.write(project, to: destination.appendingPathComponent("project.json"))
            try JSONFile.write(project.transcript!, to: destination.appendingPathComponent("transcript.json"))
            try JSONFile.write(project.candidates, to: destination.appendingPathComponent("cuts.json"))
            var options = ExportOptions()
            if !args.contains("--no-export") {
                try FFmpegRunner().export(
                    project: project,
                    to: destination.appendingPathComponent(project.media.isAudioOnly ? "cut.m4a" : "cut.mp4"),
                    options: options,
                    cancellation: cancellation
                ) { _ in }
                if args.contains("--burn") && !project.media.isAudioOnly {
                    options.burnSubtitles = true
                    try FFmpegRunner().export(
                        project: project, to: destination.appendingPathComponent("cut_burned.mp4"), options: options,
                        cancellation: cancellation
                    ) { _ in }
                }
            }
            print(
                String(
                    format: "Duration: %.3fs → %.3fs (saved %.3fs)", project.media.duration,
                    project.mapper.editedDuration, project.media.duration - project.mapper.editedDuration))
            for cut in project.candidates {
                let state = cut.enabled ? "[x]" : "[ ]"
                let adjusted = cut.isAdjusted == true ? " (adjusted)" : ""
                print(
                    String(
                        format: "%@ %@ %6.3f–%6.3f %@%@ — %@", state, cut.kind.rawValue, cut.sourceStart, cut.sourceEnd,
                        cut.text, adjusted, cut.reason))
            }
            print("Output: \(destination.path)")
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
