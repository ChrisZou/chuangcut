import Foundation
import ChuangCutCore

@main struct CLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let path = args.first, !path.hasPrefix("--") else {
                print("Usage: chuangcut-cli <input.mp4> --out <dir> [--model PATH] [--lang zh|auto] [--pause 0.6] [--burn] [--trim INDEX:left|right:SECONDS]…"); return
            }
            func value(_ key: String) -> String? { guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }; return args[i + 1] }
            guard let out = value("--out") else { throw ChuangCutError.message("--out is required") }
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let destination = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            let model = value("--model").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? ModelManager.discover().first
            guard let model else { throw ChuangCutError.message("No ggml model found. Pass --model PATH.") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var settings = DetectionSettings()
            if let pause = value("--pause") { guard let number = Double(pause), number >= 0.1 else { throw ChuangCutError.message("--pause must be at least 0.1 seconds") }; settings.pauseThreshold = number }
            let cancellation = CancellationToken()
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global()), terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            for source in [interrupt, terminate] { source.setEventHandler { cancellation.cancel() }; source.resume() }
            defer { interrupt.cancel(); terminate.cancel() }
            print("Model: \(model.lastPathComponent)")
            var project = try Pipeline().analyze(input: source, model: model, language: value("--lang") ?? "zh", settings: settings, cancellation: cancellation) { stage, percent in
                if percent == 1 || percent == 0.02 || percent == 0.8 { print("\(stage) \(Int(percent * 100))%") }
            }
            func printSegments(_ label: String) {
                print(label)
                for (i, range) in project.mapper.keptRanges.enumerated() { print(String(format: "  %d: %.3f–%.3f", i, range.start, range.end)) }
            }
            printSegments("Kept segments before trims:")
            for index in args.indices where args[index] == "--trim" {
                guard index + 1 < args.count else { throw ChuangCutError.message("--trim needs a value") }
                let trim = try TrimInstruction(args[index + 1])
                guard project.mapper.keptRanges.indices.contains(trim.segmentIndex) else { throw ChuangCutError.message("Trim segment index is out of range") }
                project.candidates = TimelineEditor.trim(duration: project.media.duration, segmentIndex: trim.segmentIndex, edge: trim.edge, newSourceTime: trim.sourceTime, cuts: project.candidates)
            }
            printSegments("Kept segments after trims:")
            try JSONFile.write(project, to: destination.appendingPathComponent("project.json"))
            try JSONFile.write(project.transcript!, to: destination.appendingPathComponent("transcript.json"))
            try JSONFile.write(project.candidates, to: destination.appendingPathComponent("cuts.json"))
            var options = ExportOptions()
            try FFmpegRunner().export(project: project, to: destination.appendingPathComponent("cut.mp4"), options: options, cancellation: cancellation) { _ in }
            if args.contains("--burn") {
                options.burnSubtitles = true
                try FFmpegRunner().export(project: project, to: destination.appendingPathComponent("cut_burned.mp4"), options: options, cancellation: cancellation) { _ in }
            }
            print(String(format: "Duration: %.3fs → %.3fs (saved %.3fs)", project.media.duration, project.mapper.editedDuration, project.media.duration - project.mapper.editedDuration))
            for cut in project.candidates {
                let state = cut.enabled ? "[x]" : "[ ]"
                let adjusted = cut.isAdjusted == true ? " (adjusted)" : ""
                print(String(format: "%@ %@ %6.3f–%6.3f %@%@ — %@", state, cut.kind.rawValue, cut.sourceStart, cut.sourceEnd, cut.text, adjusted, cut.reason))
            }
            print("Output: \(destination.path)")
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}
