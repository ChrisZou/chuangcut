import SwiftUI
import AVKit
import ChuangCutCore

@main struct ChuangCutApp: App {
    @StateObject private var model = EditorModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).frame(minWidth: 1160, minHeight: 760)
                .onAppear { delegate.model = model; model.launchArguments() }
        }
        .defaultSize(width: 1500, height: 940).windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.chooseFile() }.keyboardShortcut("o").disabled(model.busy)
                Button("Export…") { model.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.project == nil || model.busy)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo \(model.editUndoManager.undoActionName)") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo || model.busy)
                Button("Redo \(model.editUndoManager.redoActionName)") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo || model.busy)
            }
            CommandMenu("Playback") {
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayback() }.keyboardShortcut(.space, modifiers: []).disabled(model.project == nil || model.busy)
                Button("Back 5 seconds") { model.skip(-5) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(model.project == nil)
                Button("Forward 5 seconds") { model.skip(5) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(model.project == nil)
                Divider()
                Button("Split at Playhead") { model.splitAtPlayhead() }.keyboardShortcut("b").disabled(model.project == nil || model.busy)
                Button("Remove Selected Clip") { model.deleteSelectedClip() }.keyboardShortcut(.delete, modifiers: []).disabled(model.selectedSegment == nil || !model.timelineFocused || model.busy || model.showExport)
                Button("Deselect Clip") { model.selectedSegment = nil }.keyboardShortcut(.escape, modifiers: []).disabled(model.selectedSegment == nil || !model.timelineFocused || model.showExport)
            }
        }
        Settings { SettingsView(model: model) }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    func application(_ application: NSApplication, open urls: [URL]) { if let url = urls.first { model?.open(url) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.cancel() }
}
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .none; view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false; return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
final class WindowTitleView: NSView {
    var desiredTitle = "ChuangCut"
    var desiredSubtitle = ""
    func apply() { window?.title = desiredTitle; window?.subtitle = desiredSubtitle; window?.toolbar?.displayMode = .iconOnly }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
}
struct WindowIdentity: NSViewRepresentable {
    var title: String
    var subtitle: String
    func makeNSView(context: Context) -> WindowTitleView { WindowTitleView() }
    func updateNSView(_ view: WindowTitleView, context: Context) {
        view.desiredTitle = title; view.desiredSubtitle = subtitle; view.apply()
        DispatchQueue.main.async { view.apply() }
    }
}
struct ContentView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.openSettings) private var openSettings
    @State private var targeted = false
    var body: some View {
        Group {
            if model.project != nil {
                HSplitView {
                    MediaSidebar(model: model, thumbnails: model.thumbnails).frame(minWidth: 230, idealWidth: 260, maxWidth: 300)
                    VStack(spacing: 0) {
                        HSplitView {
                            PlayerPanel(model: model).frame(minWidth: 430, idealWidth: 680)
                            transcript.frame(minWidth: 340, idealWidth: 410)
                        }
                        Divider()
                        timeline
                    }.frame(minWidth: 830)
                }
            } else { emptyState }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowIdentity(title: model.project?.source.lastPathComponent ?? "ChuangCut", subtitle: model.project == nil ? "" : "\(timeLabel(model.mapper.editedDuration)) edited"))
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard !model.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.open(url) } } }; return true
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if model.busy { processing } }
        .toolbar {
            ToolbarItem(placement: .navigation) { tool("Import", "plus", action: model.chooseFile).disabled(model.busy) }
            ToolbarItemGroup(placement: .primaryAction) {
                tool("Transcribe", "text.bubble", action: model.transcribe).disabled(model.project == nil || model.busy)
                tool("Detect", "wand.and.stars", action: model.detect).disabled(model.project?.transcript == nil || model.busy)
                Toggle(isOn: $model.previewCuts) { Label("Preview", systemImage: "play.rectangle") }.toggleStyle(.button).help("Skip enabled cuts during playback")
                Toggle(isOn: $model.snapping) { Label("Snap", systemImage: "align.horizontal.center") }.toggleStyle(.button).help("Snap trim edges · hold ⌘ to bypass")
                tool("Split", "scissors", action: model.splitAtPlayhead).disabled(model.project == nil || model.busy)
                tool("Export", "square.and.arrow.up") { model.showExport = true }.disabled(model.project == nil || model.busy)
            }
        }
        .sheet(isPresented: $model.showExport) { ExportView(model: model) }
        .onChange(of: model.showSettingsRequest) { _, value in if value { openSettings(); model.showSettingsRequest = false } }
        .alert("ChuangCut", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }.help(title)
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Transcript").font(.headline); Spacer(); if let count = model.project?.transcript?.words.filter({ !$0.isPunctuation }).count { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary) } }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            Text("Click word to seek · ⌥-click cut to toggle · Select + ⌫ to cut").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if model.project?.transcript == nil {
                Spacer(); Button("Transcribe") { model.transcribe() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(model.busy); Spacer()
            } else { TranscriptView(model: model) }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var timeline: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Timeline", systemImage: "rectangle.stack").font(.system(size: 12, weight: .semibold))
                Text(model.showRemoved ? "SOURCE" : "EDITED").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show removed", isOn: $model.showRemoved).toggleStyle(.checkbox).font(.caption)
                Divider().frame(height: 16)
                Button { model.pointsPerSecond = max(5, model.pointsPerSecond / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                Slider(value: $model.pointsPerSecond, in: 5...300).frame(width: 110).accessibilityLabel("Timeline zoom")
                Button { model.pointsPerSecond = min(300, model.pointsPerSecond * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                Button { model.fitRequest += 1 } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Fit timeline").accessibilityLabel("Fit timeline")
            }.buttonStyle(.plain).padding(.horizontal, 20).frame(height: 40).background(.bar)
            TimelineView(model: model, thumbnails: model.thumbnails).frame(height: 190)
        }
    }
    private var processing: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text(model.progressLabel).font(.callout.weight(.medium))
            ProgressView(value: model.progress).frame(maxWidth: 260)
            Spacer()
            Button { model.cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Cancel").accessibilityLabel("Cancel processing")
        }.padding(.horizontal, 22).frame(height: 44).background(.regularMaterial)
    }
    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "film.stack").font(.system(size: 52, weight: .light)).foregroundStyle(.tint)
            Text("Drop a video or press ⌘O").font(.title2.weight(.medium))
            Button("Import video") { model.chooseFile() }.buttonStyle(.borderedProminent).controlSize(.large)
            let name = URL(fileURLWithPath: AppSettings.shared.modelPath).deletingPathExtension().lastPathComponent
            if FileManager.default.fileExists(atPath: (AppSettings.shared.modelPath as NSString).expandingTildeInPath) {
                Label("Model: \(name)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            } else { Button("No model — Download") { openSettings() }.buttonStyle(.link) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 20).fill(.quaternary.opacity(0.3)).padding(60))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [7])).padding(60))
    }
}
func timeLabel(_ seconds: Double) -> String { String(format: "%02d:%04.1f", Int(max(0, seconds)) / 60, max(0, seconds).truncatingRemainder(dividingBy: 60)) }
struct PlayerPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let ratio = Double(model.project?.media.width ?? 16) / Double(model.project?.media.height ?? 9)
                let width = min(geometry.size.width - 36, (geometry.size.height - 36) * ratio)
                ZStack {
                    Color(white: 0.105)
                    PlayerView(player: model.player).frame(width: max(1, width), height: max(1, width / ratio))
                        .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08)))
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                }
            }
            VStack(spacing: 12) {
                HStack(spacing: 20) {
                    Spacer()
                    Button { model.skip(-5) } label: { Image(systemName: "gobackward.5") }.help("Back 5 seconds (←)")
                    Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 30).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }.help("Play / Pause (Space)").accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                    Button { model.skip(5) } label: { Image(systemName: "goforward.5") }.help("Forward 5 seconds (→)")
                    Spacer()
                }.buttonStyle(.plain).disabled(model.busy)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(timeLabel(model.mapper.sourceToCut(model.playhead))) / \(timeLabel(model.mapper.editedDuration))").font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text("Source  \(timeLabel(model.playhead)) / \(timeLabel(model.project?.media.duration ?? 0))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Preview cuts", isOn: $model.previewCuts).toggleStyle(.switch).controlSize(.mini).font(.caption)
                    if let url = model.exportedURL { Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }.buttonStyle(.plain).help("Reveal export") }
                }
            }.padding(16).background(.bar)
        }
    }
}
