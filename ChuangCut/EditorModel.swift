import AVKit
import UniformTypeIdentifiers
import ChuangCutCore
import Combine
import SwiftUI

/// Observation tracks each property separately, so the 30 Hz playhead only refreshes the views that
/// read it instead of the sidebar and transcript.
@MainActor @Observable final class EditorModel {
    var project: Project? {
        didSet {
            // Derived once per edit; views and the playback tick read it many times per frame.
            mapper = project?.mapper ?? TimelineMapper(duration: 0, cuts: [])
            if (project == nil) != (oldValue == nil) { hasProject = project != nil }
            let transcriptChanged = project?.transcript != oldValue?.transcript
            if transcriptChanged {
                spokenWordCount = project?.transcript?.words.filter { !$0.isPunctuation }.count
            }
            // Retiming a subtitle changes nothing the cues are built from, so a drag moves the cue at once.
            if !transcriptChanged, project?.source == oldValue?.source, project?.candidates == oldValue?.candidates,
                project?.splitPoints == oldValue?.splitPoints,
                project?.subtitleEdits?.hiddenWords == oldValue?.subtitleEdits?.hiddenWords
            {
                shiftCues()
            } else {
                rebuildCues()
            }
        }
    }
    private(set) var mapper = TimelineMapper(duration: 0, cuts: [])
    /// The edit's subtitles in edited time, from the same builder as export, for the player and the timeline.
    private(set) var cues: [SubtitleCue] = []
    /// `cues` before the user's retiming, which that retiming is measured from.
    @ObservationIgnored private var unshiftedCues: [SubtitleCue] = []
    /// Changes only on open/close, so views that only need this are not refreshed on every edit.
    private(set) var hasProject = false
    private(set) var spokenWordCount: Int?
    static let zoomRange = 0.05...300.0
    var peaks: [Float] = [] { didSet { loudPeak = Self.loudPeak(peaks) } }
    /// The level loud speech reaches, ignoring the rare clipped spike; the audio-only timeline scales to it.
    private(set) var loudPeak: Float = 1
    private static func loudPeak(_ peaks: [Float]) -> Float {
        guard !peaks.isEmpty else { return 1 }
        let sorted = peaks.sorted()
        return sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
    }
    var playhead = 0.0
    var isPlaying = false
    var previewCuts = true { didSet { if previewCuts != oldValue { rebuildPlayback() } } }
    var stage = ""
    var progress = 0.0
    var error: String?
    var showExport = false
    var revision = 0
    var exportedURL: URL?
    let player = AVPlayer()
    let thumbnails = ThumbnailStore()
    let editUndoManager = UndoManager()
    var selectedSegment: Int? { didSet { if selectedSegment != nil { selectedCue = nil } } }
    /// The selected subtitle by its first word, which outlives rebuilds of the cues.
    var selectedCue: UUID? { didSet { if selectedCue != nil { selectedSegment = nil } } }
    var selectedCandidate: UUID?
    var pointsPerSecond = 40.0
    var showRemoved = false
    var snapping = true
    /// Set by the app delegate; the `--show-settings` launch hook calls it.
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored private var playbackRequested = false
    @ObservationIgnored private var hooksApplied = false
    private var trimBaseline: EditSnapshot?
    private struct EditSnapshot {
        var cuts: [CutCandidate]
        var splits: [Double]
        var transcript: Transcript?
        var silences: [TimeRange]
        var subtitles: SubtitleEdits?
    }
    private var snapshot: EditSnapshot {
        EditSnapshot(
            cuts: project?.candidates ?? [], splits: project?.splitPoints ?? [], transcript: project?.transcript,
            silences: project?.silences ?? [], subtitles: project?.subtitleEdits)
    }
    var selectedRange: TimeRange? {
        guard let i = selectedSegment, mapper.keptRanges.indices.contains(i) else { return nil }
        return mapper.keptRanges[i]
    }
    var progressLabel: String {
        if stage == L10n.Stage.transcribing || stage == L10n.Stage.exporting {
            let fraction =
                stage == L10n.Stage.transcribing ? max(0, min(1, (progress - 0.1) / 0.65)) : progress
            return "\(stage) \(Int(fraction * 100))%"
        }
        return stage
    }
    @ObservationIgnored private var observer: Any?
    /// With Preview cuts on, the player plays a composition of the kept ranges so joins are seamless;
    /// seeking past each cut in the source stalled playback for over 100 ms at every join. This is the
    /// mapper the current composition was built from, nil while the player plays the source itself.
    @ObservationIgnored private var playbackMapper: TimelineMapper?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var cancellation = CancellationToken()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var cueTask: Task<Void, Never>?
    @ObservationIgnored private var cuesStale = false
    @ObservationIgnored private var styleChange: AnyCancellable?
    /// Serial, so saves land in edit order without blocking the main thread.
    private let saveQueue = DispatchQueue(label: "ChuangCut.save", qos: .utility)
    /// Current `.chuangcut` package, if the user has saved or opened one.
    var projectPackageURL: URL?
    /// True after edits until the package is written (or no package yet).
    var isDirty = false
    @ObservationIgnored private var packageAutosave: DispatchWorkItem?
    var busy: Bool { !stage.isEmpty }
    var isTrimming: Bool { trimBaseline != nil }
    init() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.035, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        // Delivered after the new style is stored; the publisher itself fires before.
        styleChange = AppSettings.shared.$style.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.rebuildCues()
        }
    }
    func launchArguments() {
        guard !started else { return }
        started = true
        Task.detached(priority: .background) { Pipeline.removeCachedAudio() }
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
            pointsPerSecond = Self.clampZoom(zoom)
        }
        if let value = value("--select-segment"), let index = Int(value), mapper.keptRanges.indices.contains(index) {
            selectedSegment = index
        }
        pause()
        seek(value("--seek").flatMap(Double.init) ?? 0)
        if args.contains("--show-export"), project != nil { showExport = true }
        if args.contains("--show-settings") { openSettings() }
    }
    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        if !playbackRequested && player.rate != 0 { player.pause() }
        playhead = playbackMapper?.cutToSource(time) ?? time
        // Every assignment notifies observers, even of an equal value.
        let playing = playbackRequested && player.rate != 0
        if isPlaying != playing { isPlaying = playing }
    }
    /// Plays the edit as one continuous composition while Preview cuts is on, the source otherwise.
    private func rebuildPlayback() {
        playbackTask?.cancel()
        guard let project else { return }
        let mapper = mapper
        guard previewCuts, !mapper.cutRanges.isEmpty else {
            if playbackMapper != nil { setPlaybackItem(AVPlayerItem(url: project.source), mapper: nil) }
            return
        }
        playbackTask = Task { [weak self] in
            guard let item = await Self.composition(of: project.source, keeping: mapper.keptRanges),
                !Task.isCancelled
            else { return }
            self?.setPlaybackItem(item, mapper: mapper)
        }
    }
    /// The cue on screen at the playhead. Removed material has no subtitle; with Preview cuts on, a playhead
    /// inside a cut shows the frame at its join, so that frame's cue is on screen.
    var playheadCue: Int? {
        guard previewCuts || !mapper.cutRanges.contains(where: { $0.contains(playhead) }) else { return nil }
        return cueIndex(at: mapper.sourceToCut(playhead))
    }
    /// The cue covering an edited time, if any.
    func cueIndex(at time: Double) -> Int? {
        // Seeking to a cue's start comes back a hair early through the time mapping and the player's
        // timescale; that time still belongs to the cue.
        let time = time + 0.0001
        let index = firstCue(endingAfter: time)
        return index < cues.count && cues[index].start <= time ? index : nil
    }
    /// Cues are in edit order and do not overlap, so their ends are sorted.
    func firstCue(endingAfter time: Double) -> Int {
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].end > time { high = mid } else { low = mid + 1 }
        }
        return low
    }
    var selectedCueIndex: Int? { selectedCue.flatMap { id in cues.firstIndex { $0.firstWord == id } } }
    /// A trim drag changes the edit on every mouse event. One build runs at a time and the latest edit is
    /// built when it finishes, so the subtitles keep up with the drag without queueing a build per event.
    private func rebuildCues() {
        guard cueTask == nil else {
            cuesStale = true
            return
        }
        guard let project, project.transcript != nil else {
            unshiftedCues = []
            if !cues.isEmpty { cues = [] }
            return
        }
        let mapper = mapper
        let style = AppSettings.shared.style
        cueTask = Task { [weak self] in
            let cues = await Task.detached(priority: .userInitiated) {
                SubtitleBuilder(style: style).build(
                    transcript: project.transcript, mapper: mapper,
                    fillers: project.candidates.filter { $0.kind == .filler },
                    hiding: project.subtitleEdits?.hiddenWords ?? [])
            }.value
            guard let self else { return }
            cueTask = nil
            unshiftedCues = cues
            shiftCues()
            if cuesStale {
                cuesStale = false
                rebuildCues()
            }
        }
    }
    /// Applies the current retiming, which is cheap enough for every event of a drag.
    private func shiftCues() {
        let cues = (project?.subtitleEdits ?? SubtitleEdits()).shifting(
            unshiftedCues, duration: mapper.editedDuration)
        if cues != self.cues { self.cues = cues }
    }
    private func setPlaybackItem(_ item: AVPlayerItem, mapper: TimelineMapper?) {
        let time = playhead
        playbackMapper = mapper
        player.replaceCurrentItem(with: item)
        player.seek(
            to: CMTime(seconds: mapper?.sourceToCut(time) ?? time, preferredTimescale: 60000),
            toleranceBefore: .zero, toleranceAfter: .zero)
        if playbackRequested { player.play() }
    }
    private static func composition(of source: URL, keeping ranges: [TimeRange]) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        var tracks: [(AVAssetTrack, AVMutableCompositionTrack)] = []
        for type in [AVMediaType.video, .audio] {
            guard let track = try? await asset.loadTracks(withMediaType: type).first,
                let copy = composition.addMutableTrack(
                    withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            if type == .video { copy.preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity }
            tracks.append((track, copy))
        }
        guard !tracks.isEmpty else { return nil }
        var cursor = CMTime.zero
        for range in ranges {
            let span = CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: 60000),
                duration: CMTime(seconds: range.duration, preferredTimescale: 60000))
            for (track, copy) in tracks { try? copy.insertTimeRange(span, of: track, at: cursor) }
            cursor = cursor + span.duration
        }
        return AVPlayerItem(asset: composition)
    }
    func seek(_ time: Double) {
        guard time.isFinite else { return }
        let value = max(0, min(project?.media.duration ?? 0, time))
        player.seek(
            to: CMTime(seconds: playbackMapper?.sourceToCut(value) ?? value, preferredTimescale: 60000),
            toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = value
    }
    /// Seeks to a transcript word. A removed word has no place in the edit, so it seeks to the edit
    /// point where its cut begins.
    func seekWord(_ word: Word) {
        var time = word.start
        if mapper.removes(word),
            let cut = mapper.cutRanges.first(where: {
                $0.end > word.start && $0.start < max(word.end, word.start + 0.001)
            })
        {
            time = cut.start
        }
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
        // isPlaying rather than playbackRequested: at the end the player has stopped by itself, and
        // Space should restart from the beginning instead of pausing an already stopped player.
        if isPlaying {
            pause()
        } else {
            let end = playbackMapper?.keptRanges.last?.end ?? project?.media.duration ?? 0
            if playhead >= end - 0.05 { seek(0) }
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
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func chooseProject() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectPackage.pathExtension)].compactMap { $0 }
        panel.message = L10n.Menu.openProject
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }
    func saveProject() {
        guard !busy, project != nil else { return }
        if let projectPackageURL {
            writePackage(to: projectPackageURL, clearDirty: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectPackage.pathExtension)].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue =
            (project?.source.deletingPathExtension().lastPathComponent ?? "project") + ".\(ProjectPackage.pathExtension)"
        panel.message = L10n.Menu.saveProject
        if panel.runModal() == .OK, let url = panel.url {
            var package = url
            if package.pathExtension != ProjectPackage.pathExtension {
                package = package.appendingPathExtension(ProjectPackage.pathExtension)
            }
            writePackage(to: package, clearDirty: true)
            projectPackageURL = package
        }
    }
    func openProject(_ url: URL) {
        guard !busy else { return }
        pause()
        cancellation.cancel()
        cancellation = CancellationToken()
        let token = cancellation
        stage = L10n.Stage.openingProject
        progress = 0
        peaks = []
        project = nil
        projectPackageURL = nil
        isDirty = false
        editUndoManager.removeAllActions()
        selectedSegment = nil
        selectedCue = nil
        selectedCandidate = nil
        exportedURL = nil
        let tools = AppSettings.shared.tools
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try ProjectPackage.load(from: url)
                }.value
                let mediaURL = loaded.mediaURL
                let result = try await Task.detached(priority: .userInitiated) {
                    let runner = FFmpegRunner(tools: tools)
                    let media = try runner.probe(mediaURL, cancellation: token)
                    let peaks = media.hasAudio ? try runner.waveform(mediaURL, cancellation: token) : []
                    var project = loaded.project
                    project.media = media
                    project.source = mediaURL
                    return (project, peaks)
                }.value
                project = result.0
                peaks = result.1
                projectPackageURL = url
                previewCuts = loaded.state.previewCuts
                revision += 1
                playhead = loaded.state.playhead
                playbackMapper = nil
                player.replaceCurrentItem(with: AVPlayerItem(url: mediaURL))
                pause()
                seek(loaded.state.playhead)
                thumbnails.load(mediaURL, hasVideo: !(project?.media.isAudioOnly ?? false))
                rebuildPlayback()
                isDirty = false
                stage = ""
            } catch { finish(error) }
        }
    }
    private func writePackage(to packageURL: URL, clearDirty: Bool) {
        guard let project else { return }
        let state = ProjectPackage.State(
            playhead: playhead, previewCuts: previewCuts, mediaPath: project.source.path,
            mediaBookmark: ProjectPackage.makeBookmark(for: project.source))
        let snapshot = project
        saveQueue.async { [weak self] in
            do {
                try ProjectPackage.save(project: snapshot, state: state, to: packageURL)
                if clearDirty {
                    Task { @MainActor in
                        self?.isDirty = false
                        self?.projectPackageURL = packageURL
                    }
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in self?.error = message }
            }
        }
    }
    private func schedulePackageAutosave() {
        guard projectPackageURL != nil, project != nil else { return }
        packageAutosave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.projectPackageURL else { return }
            self.writePackage(to: url, clearDirty: true)
        }
        packageAutosave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }
    func open(_ url: URL, autoTranscribe: Bool = false) {
        guard !busy else { return }
        pause()
        cancellation.cancel()
        cancellation = CancellationToken()
        let token = cancellation
        stage = L10n.Stage.opening
        progress = 0
        peaks = []
        project = nil
        projectPackageURL = nil
        isDirty = false
        editUndoManager.removeAllActions()
        selectedSegment = nil
        selectedCue = nil
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
                playbackMapper = nil
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                pause()
                seek(0)
                thumbnails.load(url, hasVideo: !(project?.media.isAudioOnly ?? false))
                rebuildPlayback()
                stage = ""
                // A video seen for the first time is transcribed right away; there is no toolbar button for it.
                if autoTranscribe || project?.transcript == nil { transcribe() } else { applyLaunchHooks() }
            } catch { finish(error) }
        }
    }
    static func clampZoom(_ value: Double) -> Double {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
    }
    func transcribe() {
        guard !busy, let project else { return }
        let previous = snapshot
        let settings = AppSettings.shared
        let tools = settings.tools
        let detection = settings.detection
        let language = settings.language
        let engine: TranscriptionEngine
        switch settings.engine {
        case .success(let value): engine = value
        case .failure(let failure):
            error = failure.localizedDescription
            return
        }
        pause()
        stage = L10n.Stage.transcribing
        progress = 0
        cancellation = CancellationToken()
        let token = cancellation
        Task {
            do {
                let analyzed = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try Pipeline(tools: tools).analyze(
                        input: project.source, engine: engine, language: language, settings: detection,
                        decisions: project.decisions, cancellation: token
                    ) { stage, progress in
                        Task { @MainActor in
                            self?.stage = L10n.Stage.map(stage)
                            self?.progress = progress
                        }
                    }
                }.value
                var merged = analyzed
                merged.candidates = Self.keepingManualCuts(
                    from: self.project?.candidates ?? [], in: analyzed.candidates)
                merged.splitPoints = self.project?.splitPoints
                if previous.transcript != nil { recordUndo(L10n.Undo.transcribe, previous: previous) }
                self.project = merged
                changed()
                stage = ""
                pause()
                seek(0)
                applyLaunchHooks()
            } catch { finish(error) }
        }
    }
    func detect() {
        guard !busy, let project, project.transcript != nil else { return }
        recordUndo(L10n.Undo.detect)
        // Recompute acoustic silences when the threshold changes.
        let settings = AppSettings.shared.detection
        let tools = AppSettings.shared.tools
        stage = L10n.Stage.detecting
        progress = 0
        cancellation = CancellationToken()
        let token = cancellation
        Task {
            do {
                let result = try await Task.detached {
                    try Pipeline(tools: tools).detect(project, settings: settings, cancellation: token)
                }.value
                self.project?.transcript = result.transcript
                self.project?.silences = result.silences
                self.project?.candidates = Self.keepingManualCuts(from: project.candidates, in: result.candidates)
                changed()
                stage = ""
            } catch { finish(error) }
        }
    }
    /// Manual cuts are the user's own source-time edits, independent of the transcript and detection.
    private static func keepingManualCuts(from old: [CutCandidate], in detected: [CutCandidate]) -> [CutCandidate] {
        (detected + old.filter { $0.kind == .manual }).sorted { $0.sourceStart < $1.sourceStart }
    }
    func toggle(_ id: UUID) {
        guard !busy, let i = project?.candidates.firstIndex(where: { $0.id == id }) else { return }
        recordUndo(L10n.Undo.toggleCut)
        project?.candidates[i].enabled.toggle()
        changed()
    }
    func setAll(_ kind: CutKind, enabled: Bool) {
        guard !busy, let cuts = project?.candidates else { return }
        recordUndo(L10n.Undo.toggleGroup)
        for i in cuts.indices where cuts[i].kind == kind { project?.candidates[i].enabled = enabled }
        changed()
    }
    func manualCut(_ words: [Word]) {
        guard !busy, let start = words.first?.start, let end = words.last?.end, project != nil, end > start else {
            return
        }
        recordUndo(L10n.Undo.manualCut)
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
    }
    private func restore(_ state: EditSnapshot, name: String) {
        recordUndo(name)
        project?.candidates = state.cuts
        project?.splitPoints = state.splits
        project?.transcript = state.transcript
        project?.silences = state.silences
        project?.subtitleEdits = state.subtitles
        selectedSegment = nil
        selectedCue = nil
        changed()
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
            let selection =
                mapper.keptRanges.firstIndex { $0.contains(anchor) }
                ?? min(segment, max(0, mapper.keptRanges.count - 1))
            if selectedSegment != selection { selectedSegment = selection }
        }
        revision += 1
    }
    func endTrim() {
        guard let baseline = trimBaseline else { return }
        trimBaseline = nil
        if baseline.cuts != project?.candidates {
            recordUndo(L10n.Undo.trim, previous: baseline)
            changed()
        } else if baseline.subtitles != project?.subtitleEdits {
            recordUndo(L10n.Undo.adjustSubtitle, previous: baseline)
            save()
        }
    }
    /// Moves a subtitle's start or end, given by its anchor word, to an edited time during a drag.
    func moveCueEdge(anchor: UUID, edge: TrimEdge, to time: Double) {
        guard !busy, trimBaseline != nil,
            let cue = unshiftedCues.first(where: { (edge == .left ? $0.firstWord : $0.lastWord) == anchor })
        else { return }
        let shift = time - (edge == .left ? cue.start : cue.end)
        var edits = project?.subtitleEdits ?? SubtitleEdits()
        // Back where its words put it, an edge needs no shift.
        let value = abs(shift) < 0.0005 ? nil : shift
        if edge == .left { edits.startShifts[anchor] = value } else { edits.endShifts[anchor] = value }
        project?.subtitleEdits = edits
    }
    /// Deletes the selected subtitle. Its words stay out of the subtitles through later edits; the speech
    /// stays in the video.
    func deleteSelectedCue() {
        guard !busy, let index = selectedCueIndex, let words = project?.transcript?.words,
            let first = words.firstIndex(where: { $0.id == cues[index].firstWord }),
            let last = words[first...].firstIndex(where: { $0.id == cues[index].lastWord })
        else { return }
        recordUndo(L10n.Undo.deleteSubtitle)
        var edits = project?.subtitleEdits ?? SubtitleEdits()
        for word in words[first...last] {
            edits.hiddenWords.insert(word.id)
            edits.startShifts[word.id] = nil
            edits.endShifts[word.id] = nil
        }
        project?.subtitleEdits = edits
        selectedCue = nil
        save()
    }
    func deleteSelectedClip() {
        guard !busy, let range = selectedRange else { return }
        recordUndo(L10n.Undo.removeClip)
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
        recordUndo(L10n.Undo.split)
        project?.splitPoints = (project?.splitPoints ?? []) + [playhead]
        changed()
        selectSegment(at: playhead)
    }
    private func changed() {
        revision += 1
        isDirty = projectPackageURL != nil
        rebuildPlayback()
        save()
    }
    /// Subtitle edits only need saving: the transcript and the playback composition stay as they are.
    private func save() {
        guard let project else { return }
        if projectPackageURL != nil { isDirty = true }
        // Encoding a long transcript takes tens of milliseconds.
        saveQueue.async { [weak self] in
            do { try Pipeline.save(project) } catch {
                let message = error.localizedDescription
                Task { @MainActor in self?.error = message }
            }
        }
        schedulePackageAutosave()
    }
    func finishSaving() { saveQueue.sync {} }
    func cancel() { cancellation.cancel() }
    private func finish(_ error: Error) {
        stage = ""
        if !(error is CancellationError) { self.error = error.localizedDescription }
    }
    func export(to url: URL, options: ExportOptions) {
        guard !busy, let project else { return }
        stage = L10n.Stage.exporting
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
