import AVKit
import ChuangCutCore
import SwiftUI

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
    let thumbnails = ThumbnailStore()
    let editUndoManager = UndoManager()
    @Published var timelineFocused = false
    @Published var selectedSegment: Int?
    @Published var selectedCandidate: UUID?
    @Published var pointsPerSecond = 40.0
    @Published var showRemoved = false
    @Published var snapping = true
    @Published var showSettingsRequest = false
    @Published var undoVersion = 0
    @Published var fitRequest = 0
    private var playbackRequested = false
    private var hooksApplied = false
    private var trimBaseline: EditSnapshot?
    private struct EditSnapshot {
        var cuts: [CutCandidate]
        var splits: [Double]
    }
    private var snapshot: EditSnapshot {
        EditSnapshot(cuts: project?.candidates ?? [], splits: project?.splitPoints ?? [])
    }
    var selectedRange: TimeRange? {
        guard let i = selectedSegment, mapper.keptRanges.indices.contains(i) else { return nil }
        return mapper.keptRanges[i]
    }
    var progressLabel: String {
        if stage == "Transcribing" || stage == "Exporting" {
            return
                "\(stage) \(Int((stage == "Transcribing" ? max(0, min(1, (progress - 0.1) / 0.65)) : progress) * 100))%"
        }
        return stage
    }
    private var observer: Any?
    private var boundaryObserver: Any?
    private var seeking = false
    private var cancellation = CancellationToken()
    private var started = false
    var busy: Bool { !stage.isEmpty }
    var canUndo: Bool { editUndoManager.canUndo }
    var canRedo: Bool { editUndoManager.canRedo }
    var mapper: TimelineMapper { project?.mapper ?? TimelineMapper(duration: 0, cuts: []) }
    init() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.035, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
    }
    func launchArguments() {
        guard !started else { return }
        started = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            open(URL(fileURLWithPath: args[i + 1]), autoTranscribe: args.contains("--auto-transcribe"))
        } else {
            applyLaunchHooks()
        }
    }
    private func applyLaunchHooks() {
        guard !hooksApplied else { return }
        hooksApplied = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        for i in args.indices where args[i] == "--trim" && i + 1 < args.count {
            if let instruction = try? TrimInstruction(args[i + 1]), let project {
                self.project?.candidates = TimelineEditor.trim(
                    duration: project.media.duration, segmentIndex: instruction.segmentIndex, edge: instruction.edge,
                    newSourceTime: instruction.sourceTime, cuts: project.candidates, splits: project.splitPoints ?? [])
                changed()
            }
        }
        if let value = value("--zoom"), let zoom = Double(value), zoom.isFinite {
            pointsPerSecond = max(5, min(300, zoom))
        }
        if let value = value("--select-segment"), let index = Int(value), mapper.keptRanges.indices.contains(index) {
            selectedSegment = index
        }
        pause()
        seek(value("--seek").flatMap(Double.init) ?? 0)
        if args.contains("--show-export"), project != nil { showExport = true }
        if args.contains("--show-settings") { showSettingsRequest = true }
    }
    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        if !playbackRequested && player.rate != 0 { player.pause() }
        playhead = time
        isPlaying = playbackRequested && player.rate != 0
        skipCut(at: time)
    }
    private func skipCut(at time: Double) {
        guard previewCuts, player.rate > 0, !seeking, let cut = mapper.cutRanges.first(where: { $0.contains(time) })
        else { return }
        seeking = true
        player.seek(
            to: CMTime(seconds: cut.end, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in self?.seeking = false }
        }
    }
    private func rebuildBoundaries() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        let times = mapper.cutRanges.map { NSValue(time: CMTime(seconds: $0.start, preferredTimescale: 60000)) }
        if !times.isEmpty {
            boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.skipCut(at: self.player.currentTime().seconds + 0.002)
                }
            }
        }
    }
    func seek(_ time: Double) {
        guard time.isFinite else { return }
        let value = max(0, min(project?.media.duration ?? 0, time))
        player.seek(
            to: CMTime(seconds: value, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = value
    }
    func seekWord(_ time: Double) {
        timelineFocused = false
        selectSegment(at: time)
        seek(time)
    }
    func selectSegment(at time: Double) {
        selectedSegment = mapper.keptRanges.firstIndex { $0.contains(time) }
        selectedCandidate = nil
    }
    func selectCandidate(_ cut: CutCandidate) {
        selectedCandidate = cut.id
        selectedSegment = nil
        seek(cut.sourceStart)
    }
    func pause() {
        playbackRequested = false
        player.pause()
        isPlaying = false
    }
    func togglePlayback() {
        guard !busy else { return }
        if playbackRequested {
            pause()
        } else {
            if playhead >= (project?.media.duration ?? 0) - 0.05 { seek(0) }
            playbackRequested = true
            player.play()
            isPlaying = true
        }
    }
    func skip(_ seconds: Double) {
        let time = mapper.sourceToCut(playhead) + seconds
        seek(previewCuts ? mapper.cutToSource(time) : playhead + seconds)
    }
    func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, autoTranscribe: Bool = false) {
        guard !busy else { return }
        pause()
        cancellation.cancel()
        cancellation = CancellationToken()
        let token = cancellation
        stage = "Opening"
        progress = 0
        peaks = []
        project = nil
        editUndoManager.removeAllActions()
        selectedSegment = nil
        selectedCandidate = nil
        exportedURL = nil
        let tools = AppSettings.shared.tools
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let runner = FFmpegRunner(tools: tools)
                    let media = try runner.probe(url, cancellation: token)
                    let saved = try Pipeline.restore(url)
                    let peaks = media.hasAudio ? try runner.waveform(url, cancellation: token) : []
                    var project = saved ?? Project(source: url, media: media)
                    project.media = media
                    return (project, peaks)
                }.value
                project = result.0
                peaks = result.1
                revision += 1
                playhead = 0
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                pause()
                seek(0)
                thumbnails.load(url)
                rebuildBoundaries()
                stage = ""
                if autoTranscribe { transcribe() } else { applyLaunchHooks() }
            } catch { finish(error) }
        }
    }
    func transcribe() {
        guard !busy, let project else { return }
        let settings = AppSettings.shared
        let tools = settings.tools
        let detection = settings.detection
        let language = settings.language
        let model = URL(fileURLWithPath: (settings.modelPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: model.path), !settings.modelPath.isEmpty else {
            error = "Choose or download a Whisper model in Settings."
            return
        }
        pause()
        stage = "Transcribing"
        progress = 0
        cancellation = CancellationToken()
        let token = cancellation
        Task {
            do {
                let analyzed = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try Pipeline(tools: tools).analyze(
                        input: project.source, model: model, language: language, settings: detection,
                        cancellation: token
                    ) { stage, progress in
                        Task { @MainActor in
                            self?.stage = stage
                            self?.progress = progress
                        }
                    }
                }.value
                self.project = analyzed
                editUndoManager.removeAllActions()
                revision += 1
                rebuildBoundaries()
                stage = ""
                pause()
                seek(0)
                applyLaunchHooks()
            } catch { finish(error) }
        }
    }
    func detect() {
        guard !busy, let project, let transcript = project.transcript else { return }
        recordUndo("Detect cuts")
        // Recompute acoustic silences when the threshold changes.
        let settings = AppSettings.shared.detection
        let tools = AppSettings.shared.tools
        stage = "Detecting cuts"
        progress = 0
        cancellation = CancellationToken()
        let token = cancellation
        Task {
            do {
                let result = try await Task.detached {
                    let silences = try FFmpegRunner(tools: tools).silence(
                        project.source, threshold: settings.pauseThreshold, duration: project.media.duration,
                        cancellation: token)
                    return (
                        silences,
                        CutDetector(settings: settings).detect(
                            words: transcript.words, duration: project.media.duration, silences: silences)
                    )
                }.value
                self.project?.silences = result.0
                self.project?.candidates = result.1
                changed()
                stage = ""
            } catch { finish(error) }
        }
    }
    func toggle(_ id: UUID) {
        guard !busy, let i = project?.candidates.firstIndex(where: { $0.id == id }) else { return }
        recordUndo("Toggle cut")
        project?.candidates[i].enabled.toggle()
        changed()
    }
    func setAll(_ kind: CutKind, enabled: Bool) {
        guard !busy, let cuts = project?.candidates else { return }
        recordUndo("Toggle group")
        for i in cuts.indices where cuts[i].kind == kind { project?.candidates[i].enabled = enabled }
        changed()
    }
    func manualCut(_ words: [Word]) {
        guard !busy, let start = words.first?.start, let end = words.last?.end, project != nil, end > start else {
            return
        }
        recordUndo("Manual cut")
        project?.candidates.append(
            CutCandidate(
                kind: .manual, start: start, end: end, text: words.map(\.text).joined(),
                reason: "Selected transcript text"))
        changed()
    }
    private func recordUndo(_ name: String, previous: EditSnapshot? = nil) {
        let old = previous ?? snapshot
        editUndoManager.registerUndo(withTarget: self) { target in target.restore(old, name: name) }
        editUndoManager.setActionName(name)
        undoVersion += 1
    }
    private func restore(_ state: EditSnapshot, name: String) {
        recordUndo(name)
        project?.candidates = state.cuts
        project?.splitPoints = state.splits
        selectedSegment = nil
        changed()
    }
    func undo() {
        guard !busy else { return }
        editUndoManager.undo()
        undoVersion += 1
    }
    func redo() {
        guard !busy else { return }
        editUndoManager.redo()
        undoVersion += 1
    }
    func beginTrim() {
        guard !busy else { return }
        pause()
        trimBaseline = snapshot
    }
    func trim(segment: Int, edge: TrimEdge, time: Double) {
        guard !busy, let baseline = trimBaseline, let project else { return }
        self.project?.candidates = TimelineEditor.trim(
            duration: project.media.duration, segmentIndex: segment, edge: edge, newSourceTime: time,
            cuts: baseline.cuts, splits: baseline.splits)
        let before = TimelineMapper(duration: project.media.duration, cuts: baseline.cuts, splits: baseline.splits)
            .keptRanges
        if before.indices.contains(segment) {
            let anchor = (before[segment].start + before[segment].end) / 2
            selectedSegment =
                mapper.keptRanges.firstIndex { $0.contains(anchor) }
                ?? min(segment, max(0, mapper.keptRanges.count - 1))
        }
        revision += 1
    }
    func endTrim() {
        guard let baseline = trimBaseline else { return }
        trimBaseline = nil
        if baseline.cuts != project?.candidates {
            recordUndo("Trim clip", previous: baseline)
            changed()
        }
    }
    func deleteSelectedClip() {
        guard !busy, let range = selectedRange else { return }
        recordUndo("Remove clip")
        project?.candidates.append(
            CutCandidate(
                kind: .manual, start: range.start, end: range.end, text: "Removed clip", reason: "Timeline selection"))
        selectedSegment = nil
        changed()
    }
    func splitAtPlayhead() {
        guard !busy, let range = mapper.keptRanges.first(where: { $0.contains(playhead) }),
            playhead - range.start >= 0.1, range.end - playhead >= 0.1
        else { return }
        recordUndo("Split clip")
        project?.splitPoints = (project?.splitPoints ?? []) + [playhead]
        changed()
        selectSegment(at: playhead)
    }
    private func changed() {
        revision += 1
        rebuildBoundaries()
        if let project { do { try Pipeline.save(project) } catch { self.error = error.localizedDescription } }
    }
    func cancel() { cancellation.cancel() }
    private func finish(_ error: Error) {
        stage = ""
        if !(error is CancellationError) { self.error = error.localizedDescription }
    }
    func export(to url: URL, options: ExportOptions) {
        guard !busy, let project else { return }
        stage = "Exporting"
        progress = 0
        pause()
        cancellation = CancellationToken()
        let token = cancellation
        let tools = AppSettings.shared.tools
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [weak self] in
                    try FFmpegRunner(tools: tools).export(
                        project: project, to: url, options: options, cancellation: token
                    ) { progress in
                        Task { @MainActor in self?.progress = progress }
                    }
                }.value
                stage = ""
                exportedURL = url
            } catch { finish(error) }
        }
    }
}
