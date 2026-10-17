import SwiftUI
import AVKit
import UniformTypeIdentifiers
import ChuangCutCore

@main struct ChuangCutApp: App {
    @StateObject private var model = EditorModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).frame(minWidth: 1050, minHeight: 650)
                .onAppear { delegate.model = model; model.launchArguments() }
        }
        .defaultSize(width: 1440, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.chooseFile() }.keyboardShortcut("o").disabled(model.busy)
                Button("Export…") { model.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.project == nil || model.busy)
            }
            CommandGroup(replacing: .undoRedo) { Button("Undo Cut Change") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo || model.busy) }
            CommandMenu("Playback") { Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayback() }.keyboardShortcut(.space, modifiers: []).disabled(model.project == nil) }
        }
        Settings { SettingsView() }
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
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .floating; view.videoGravity = .resizeAspect; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
struct ContentView: View {
    @ObservedObject var model: EditorModel
    @State private var targeted = false
    var body: some View {
        Group {
            if let project = model.project {
                HSplitView {
                    sidebar(project).frame(minWidth: 205, idealWidth: 235, maxWidth: 300)
                    VStack(spacing: 0) {
                        PlayerView(player: model.player).background(.black).frame(maxWidth: .infinity, maxHeight: .infinity)
                        HStack(spacing: 12) {
                            Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16) }.buttonStyle(.plain).help("Play / Pause (Space)").accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                            Text(SubtitleBuilder.timestamp(model.playhead).replacingOccurrences(of: ",", with: ".")).monospacedDigit().font(.system(size: 11, design: .monospaced))
                            Spacer()
                            if let url = model.exportedURL { Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }.buttonStyle(.plain).help("Show exported video in Finder") }
                            Image(systemName: "waveform").foregroundStyle(.tertiary).help("Pinch or ⌘ scroll to zoom")
                        }.padding(.horizontal, 16).padding(.vertical, 12).background(.bar)
                        TimelineView(model: model).frame(height: 140)
                    }.frame(minWidth: 420, idealWidth: 680)
                    VStack(spacing: 0) {
                        HStack {
                            Text("Transcript").font(.headline); Spacer()
                            Image(systemName: "cursorarrow.click.2").foregroundStyle(.secondary).help("Click a word to seek · Option-click a cut to toggle · Select and Delete to cut")
                        }.padding(18)
                        Divider()
                        if project.transcript == nil {
                            VStack { Spacer(); Button("Transcribe") { model.transcribe() }.buttonStyle(.borderedProminent).disabled(model.busy); Spacer() }.frame(maxWidth: .infinity)
                        } else { TranscriptView(model: model) }
                    }.frame(minWidth: 320, idealWidth: 405).background(.background)
                }
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "film.stack").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text("Drop a video").font(.title2.weight(.medium))
                    Button("Open…") { model.chooseFile() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [7])).padding(55) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard !model.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.open(url) } } }; return true
        }
        .overlay(alignment: .bottom) {
            if model.busy {
                HStack(spacing: 14) {
                    ProgressView(value: model.progress).frame(width: 160)
                    Text(model.stage).font(.callout).frame(minWidth: 90, alignment: .leading)
                    Button { model.cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Cancel").accessibilityLabel("Cancel")
                }.padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 8, y: 3).padding(24)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.chooseFile() } label: { Label("Import", systemImage: "plus") }.help("Import video (⌘O)").disabled(model.busy)
            }
            ToolbarItem(placement: .principal) {
                if let project = model.project {
                    HStack(spacing: 8) {
                        Text(project.source.lastPathComponent).fontWeight(.medium).lineLimit(1)
                        Text(String(format: "%.1fs → %.1fs", project.media.duration, model.mapper.editedDuration)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.transcribe() } label: { Label("Transcribe", systemImage: "text.bubble") }.help("Transcribe").disabled(model.project == nil || model.busy)
                Button { model.detect() } label: { Label("Detect", systemImage: "wand.and.stars") }.help("Detect cuts").disabled(model.project?.transcript == nil || model.busy)
                Toggle(isOn: $model.previewCuts) { Label("Preview cuts", systemImage: "scissors") }.toggleStyle(.button).help("Skip enabled cuts during playback").disabled(model.project == nil)
                Button { model.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.help("Export (⇧⌘E)").disabled(model.project == nil || model.busy)
            }
        }
        .sheet(isPresented: $model.showExport) { ExportView(model: model) }
        .alert("ChuangCut", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private func sidebar(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Cuts", systemImage: "slider.horizontal.3").font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "−%.1f", project.media.duration - model.mapper.editedDuration)).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("seconds").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(project.media.width) × \(project.media.height)").font(.caption).foregroundStyle(.tertiary)
            }.padding(18)
            Divider()
            List {
                ForEach(CutKind.allCases, id: \.self) { kind in
                    let cuts = project.candidates.filter { $0.kind == kind }
                    Section {
                        ForEach(cuts) { cut in
                            HStack(alignment: .top, spacing: 7) {
                                Toggle("Enable \(cut.text)", isOn: Binding(get: { cut.enabled }, set: { _ in model.toggle(cut.id) })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                                Button { model.seek(cut.sourceStart) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(cut.text).lineLimit(2).foregroundStyle(cut.enabled ? .primary : .secondary)
                                        Text(String(format: "%.2f–%.2f", cut.sourceStart, cut.sourceEnd)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(cut.reason)
                            }.padding(.vertical, 4)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                            Text(kind.title)
                            Text("\(cuts.filter(\.enabled).count)/\(cuts.count)").foregroundStyle(.tertiary).monospacedDigit()
                            Spacer(minLength: 0)
                            Button { model.setAll(kind, enabled: !cuts.allSatisfy(\.enabled)) } label: { Image(systemName: cuts.allSatisfy(\.enabled) ? "minus.circle" : "checkmark.circle") }.buttonStyle(.plain).help(cuts.allSatisfy(\.enabled) ? "Disable all \(kind.title)" : "Enable all \(kind.title)").accessibilityLabel(cuts.allSatisfy(\.enabled) ? "Disable all \(kind.title)" : "Enable all \(kind.title)").disabled(cuts.isEmpty || model.busy)
                        }.font(.caption)
                    }
                }
            }.listStyle(.sidebar)
        }.background(.bar)
    }
}
