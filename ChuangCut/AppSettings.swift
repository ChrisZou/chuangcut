import SwiftUI
import ChuangCutCore

@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var modelPath: String { didSet { defaults.set(modelPath, forKey: "modelPath") } }
    @Published var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    @Published var whisperPath: String { didSet { defaults.set(whisperPath, forKey: "whisperPath") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var pause: Double { didSet { defaults.set(pause, forKey: "pause") } }
    @Published var padding: Double { didSet { defaults.set(padding, forKey: "padding") } }
    @Published var fillerText: String { didSet { defaults.set(fillerText, forKey: "fillers") } }
    @Published var style: SubtitleStyle { didSet { if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: "subtitleStyle") } } }
    private let defaults = UserDefaults.standard
    init() {
        let d = UserDefaults.standard
        modelPath = d.string(forKey: "modelPath") ?? ModelManager.recommended.map { ModelManager.directory.appendingPathComponent($0).path }.first { FileManager.default.fileExists(atPath: $0) } ?? ""
        ffmpegPath = d.string(forKey: "ffmpegPath") ?? ToolPaths.resolve("ffmpeg")
        whisperPath = d.string(forKey: "whisperPath") ?? ToolPaths.resolve("whisper-cli")
        language = d.string(forKey: "language") ?? "zh"
        pause = d.object(forKey: "pause") as? Double ?? 0.6
        padding = d.object(forKey: "padding") as? Double ?? 0.1
        fillerText = d.string(forKey: "fillers") ?? DetectionSettings().fillers.joined(separator: ", ")
        style = d.data(forKey: "subtitleStyle").flatMap { try? JSONDecoder().decode(SubtitleStyle.self, from: $0) } ?? SubtitleStyle()
    }
    var tools: ToolPaths { ToolPaths(ffmpeg: (ffmpegPath as NSString).expandingTildeInPath, whisper: (whisperPath as NSString).expandingTildeInPath) }
    var detection: DetectionSettings {
        var value = DetectionSettings(); value.pauseThreshold = max(0.1, pause); value.padding = min(max(0, padding), value.pauseThreshold / 2)
        value.fillers = fillerText.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; return value
    }
}
