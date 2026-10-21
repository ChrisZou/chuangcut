import ChuangCutCore
import SwiftUI

enum Transcriber: String, CaseIterable {
    case doubao, whisper
}

@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var transcriber: Transcriber { didSet { defaults.set(transcriber.rawValue, forKey: "transcriber") } }
    @Published var doubaoKey: String { didSet { defaults.set(doubaoKey, forKey: "doubaoKey") } }
    @Published var hotwordTable: String { didSet { defaults.set(hotwordTable, forKey: "hotwordTable") } }
    @Published var modelPath: String { didSet { defaults.set(modelPath, forKey: "modelPath") } }
    @Published var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    @Published var whisperPath: String { didSet { defaults.set(whisperPath, forKey: "whisperPath") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var pause: Double { didSet { defaults.set(pause, forKey: "pause") } }
    @Published var leadIn: Double { didSet { defaults.set(leadIn, forKey: "leadIn") } }
    @Published var tail: Double { didSet { defaults.set(tail, forKey: "tail") } }
    @Published var fillerText: String { didSet { defaults.set(fillerText, forKey: "fillers") } }
    @Published var style: SubtitleStyle {
        didSet { if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: "subtitleStyle") } }
    }
    private let defaults = UserDefaults.standard
    init() {
        let d = UserDefaults.standard
        transcriber = d.string(forKey: "transcriber").flatMap(Transcriber.init) ?? .doubao
        doubaoKey = d.string(forKey: "doubaoKey") ?? ""
        hotwordTable = d.string(forKey: "hotwordTable") ?? ""
        modelPath =
            d.string(forKey: "modelPath") ?? ModelManager.recommended.map {
                ModelManager.directory.appendingPathComponent($0).path
            }.first { FileManager.default.fileExists(atPath: $0) } ?? ""
        ffmpegPath = d.string(forKey: "ffmpegPath") ?? ToolPaths.resolve("ffmpeg")
        whisperPath = d.string(forKey: "whisperPath") ?? ToolPaths.resolve("whisper-cli")
        language = d.string(forKey: "language") ?? "zh"
        pause = d.object(forKey: "pause") as? Double ?? 0.6
        leadIn = d.object(forKey: "leadIn") as? Double ?? DetectionSettings().leadIn
        tail = d.object(forKey: "tail") as? Double ?? DetectionSettings().tail
        fillerText = d.string(forKey: "fillers") ?? DetectionSettings().fillers.joined(separator: ", ")
        style =
            d.data(forKey: "subtitleStyle").flatMap { try? JSONDecoder().decode(SubtitleStyle.self, from: $0) }
            ?? SubtitleStyle()
    }
    /// The engine to transcribe with, or why transcription can't start.
    var engine: Result<TranscriptionEngine, ChuangCutError> {
        switch transcriber {
        case .doubao:
            let key = doubaoKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return .failure(.message("Add your Doubao API key in Settings, or switch to Whisper."))
            }
            let table = hotwordTable.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(.doubao(apiKey: key, hotwordTable: table.isEmpty ? nil : table))
        case .whisper:
            let model = (modelPath as NSString).expandingTildeInPath
            guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: model) else {
                return .failure(.message("Choose or download a Whisper model in Settings."))
            }
            return .success(.whisper(model: URL(fileURLWithPath: model)))
        }
    }
    var tools: ToolPaths {
        ToolPaths(
            ffmpeg: (ffmpegPath as NSString).expandingTildeInPath,
            whisper: (whisperPath as NSString).expandingTildeInPath)
    }
    var detection: DetectionSettings {
        var value = DetectionSettings()
        value.pauseThreshold = max(0.1, pause)
        value.leadIn = max(0, leadIn)
        value.tail = max(0, tail)
        value.fillers = fillerText.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return value
    }
}
