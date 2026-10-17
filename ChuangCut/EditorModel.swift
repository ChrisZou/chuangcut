import SwiftUI
import AVKit
import ChuangCutCore

@MainActor final class EditorModel: ObservableObject {
    @Published var project: Project?
    @Published var peaks: [Float] = []
    @Published var playhead = 0.0
    @Published var isPlaying = false
    @Published var previewCuts = true
    @Published var stage = ""
    @Published var progress = 0.0
    @Published var error: String?
    @Published var showExport = false
    @Published var revision = 0
    @Published var exportedURL: URL?
    let player = AVPlayer()
    private var observer: Any?
    private var boundaryObserver: Any?
    private var seeking = false
    private var cancellation = CancellationToken()
    private var history: [[CutCandidate]] = []
    private var started = false
    var busy: Bool { !stage.isEmpty }
    var canUndo: Bool { !history.isEmpty }
    var mapper: TimelineMapper { project?.mapper ?? TimelineMapper(duration: 0, cuts: []) }
    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.035, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
    }
    func launchArguments() {
        guard !started else { return }; started = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count { open(URL(fileURLWithPath: args[i + 1]), autoTranscribe: args.contains("--auto-transcribe")) }
    }
    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        playhead = time; isPlaying = player.rate != 0
        skipCut(at: time)
    }
    private func skipCut(at time: Double) {
        guard previewCuts, player.rate > 0, !seeking, let cut = mapper.cutRanges.first(where: { $0.contains(time) }) else { return }
        seeking = true
        player.seek(to: CMTime(seconds: cut.end, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seeking = false }
        }
    }
    private func rebuildBoundaries() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver); self.boundaryObserver = nil }
        let times = mapper.cutRanges.map { NSValue(time: CMTime(seconds: $0.start, preferredTimescale: 60000)) }
        if !times.isEmpty {
            boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
                Task { @MainActor in guard let self else { return }; self.skipCut(at: self.player.currentTime().seconds + 0.002) }
            }
        }
    }
    func seek(_ time: Double) {
        player.seek(to: CMTime(seconds: max(0, min(project?.media.duration ?? 0, time)), preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = time
    }
    func togglePlayback() { if player.rate == 0 { if playhead >= (project?.media.duration ?? 0) - 0.05 { seek(0) }; player.play() } else { player.pause() }; isPlaying = player.rate != 0 }
    func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, autoTranscribe: Bool = false) {
        guard !busy else { return }
        player.pause(); cancellation.cancel(); cancellation = CancellationToken(); let token = cancellation
        stage = "Opening"; progress = 0; peaks = []; project = nil; history = []; exportedURL = nil
        let tools = AppSettings.shared.tools
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let runner = FFmpegRunner(tools: tools)
                    let media = try runner.probe(url, cancellation: token)
                    let saved = try Pipeline.restore(url)
                    let peaks = media.hasAudio ? try runner.waveform(url, cancellation: token) : []
                    return (saved ?? Project(source: url, media: media), peaks)
                }.value
                project = result.0; peaks = result.1; revision += 1; playhead = 0
                player.replaceCurrentItem(with: AVPlayerItem(url: url)); rebuildBoundaries(); stage = ""
                if autoTranscribe { transcribe() }
            } catch { finish(error) }
        }
    }
    func transcribe() {
        guard !busy, let project else { return }
        let settings = AppSettings.shared, tools = settings.tools, detection = settings.detection, language = settings.language
        let model = URL(fileURLWithPath: (settings.modelPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: model.path), !settings.modelPath.isEmpty else { error = "Choose or download a Whisper model in Settings."; return }
        player.pause(); stage = "Transcribing"; progress = 0; cancellation = CancellationToken(); let token = cancellation
        Task {
            do {
                let analyzed = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try Pipeline(tools: tools).analyze(input: project.source, model: model, language: language, settings: detection, cancellation: token) { stage, progress in
                        Task { @MainActor in self?.stage = stage; self?.progress = progress }
                    }
                }.value
                self.project = analyzed; history = []; revision += 1; rebuildBoundaries(); stage = ""
            } catch { finish(error) }
        }
    }
    func detect() {
        guard !busy, let project, let transcript = project.transcript else { return }
        history.append(project.candidates)
        // Recompute acoustic silences when the threshold changes.
        let settings = AppSettings.shared.detection, tools = AppSettings.shared.tools
        stage = "Detecting cuts"; progress = 0; cancellation = CancellationToken(); let token = cancellation
        Task {
            do {
                let result = try await Task.detached {
                    let silences = try FFmpegRunner(tools: tools).silence(project.source, threshold: settings.pauseThreshold, duration: project.media.duration, cancellation: token)
                    return (silences, CutDetector(settings: settings).detect(words: transcript.words, duration: project.media.duration, silences: silences))
                }.value
                self.project?.silences = result.0; self.project?.candidates = result.1; changed(); stage = ""
            } catch { finish(error) }
        }
    }
    func toggle(_ id: UUID) {
        guard !busy, let i = project?.candidates.firstIndex(where: { $0.id == id }), let cuts = project?.candidates else { return }
        history.append(cuts); project?.candidates[i].enabled.toggle(); changed()
    }
    func setAll(_ kind: CutKind, enabled: Bool) {
        guard !busy, let cuts = project?.candidates else { return }; history.append(cuts)
        for i in cuts.indices where cuts[i].kind == kind { project?.candidates[i].enabled = enabled }; changed()
    }
    func manualCut(_ words: [Word]) {
        guard !busy, let start = words.first?.start, let end = words.last?.end, let cuts = project?.candidates, end > start else { return }
        history.append(cuts)
        project?.candidates.append(CutCandidate(kind: .manual, start: start, end: end, text: words.map(\.text).joined(), reason: "Selected transcript text")); changed()
    }
    func undo() { guard !busy, let previous = history.popLast() else { return }; project?.candidates = previous; changed() }
    private func changed() {
        revision += 1; rebuildBoundaries()
        if let project { do { try Pipeline.save(project) } catch { self.error = error.localizedDescription } }
    }
    func cancel() { cancellation.cancel() }
    private func finish(_ error: Error) { stage = ""; if !(error is CancellationError) { self.error = error.localizedDescription } }
    func export(to url: URL, options: ExportOptions) {
        guard !busy, let project else { return }
        stage = "Exporting"; progress = 0; player.pause(); cancellation = CancellationToken(); let token = cancellation, tools = AppSettings.shared.tools
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [weak self] in
                    try FFmpegRunner(tools: tools).export(project: project, to: url, options: options, cancellation: token) { progress in
                        Task { @MainActor in self?.progress = progress }
                    }
                }.value
                stage = ""; exportedURL = url
            } catch { finish(error) }
        }
    }
}
