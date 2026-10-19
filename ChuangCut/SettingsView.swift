import ChuangCutCore
import SwiftUI

struct SettingsView: View {
    var model: EditorModel
    @ObservedObject var settings = AppSettings.shared
    @State private var found: [URL] = []
    @State private var modelName = ModelManager.recommended[0]
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var error: String?
    @State private var manager = ModelManager()
    var body: some View {
        TabView {
            Form {
                Section("Whisper model") {
                    HStack {
                        TextField("Model path", text: $settings.modelPath)
                        Button {
                            chooseModel()
                        } label: {
                            Image(systemName: "folder")
                        }.help("Choose model").accessibilityLabel("Choose model")
                    }
                    if !found.isEmpty {
                        Picker("Installed", selection: $settings.modelPath) {
                            if !found.contains(where: { $0.path == settings.modelPath }) {
                                Text(
                                    settings.modelPath.isEmpty
                                        ? "Choose a model" : URL(fileURLWithPath: settings.modelPath).lastPathComponent
                                ).tag(settings.modelPath)
                            }
                            ForEach(found, id: \.path) { Text($0.lastPathComponent).tag($0.path) }
                        }
                    }
                    Picker("Download", selection: $modelName) {
                        ForEach(ModelManager.recommended, id: \.self) {
                            Text(
                                $0.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(
                                    of: ".bin", with: "")
                            ).tag($0)
                        }
                    }
                    HStack {
                        if downloading {
                            ProgressView(value: progress)
                            Button("Cancel") { manager.cancel() }
                        } else {
                            Button("Download") { download() }
                            Spacer()
                            Button {
                                refresh(includeDownloads: true)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }.help("Find models, including Downloads")
                        }
                    }
                }
                Section("Tools") {
                    TextField("ffmpeg", text: $settings.ffmpegPath)
                    TextField("whisper-cli", text: $settings.whisperPath)
                }
            }.formStyle(.grouped).tabItem { Label("Models", systemImage: "cpu") }
            Form {
                Picker("Language", selection: $settings.language) {
                    Text("中文").tag("zh")
                    Text("Auto").tag("auto")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Español").tag("es")
                }
                HStack {
                    Text("Pause threshold")
                    Slider(value: $settings.pause, in: 0.2...2, step: 0.05)
                    Text(String(format: "%.2f s", settings.pause)).monospacedDigit().frame(width: 55)
                }
                HStack {
                    Text("Keep padding")
                    Slider(value: $settings.padding, in: 0...0.25, step: 0.01)
                    Text(String(format: "%.2f s", settings.padding)).monospacedDigit().frame(width: 55)
                }
                TextField("Fillers", text: $settings.fillerText, axis: .vertical).lineLimit(3...5)
            }.formStyle(.grouped).tabItem { Label("Detection", systemImage: "waveform") }
            VStack(spacing: 12) {
                SubtitlePreview(model: model, thumbnails: model.thumbnails, style: settings.style).padding(
                    .horizontal, 20)
                Form { SubtitleStyleControls(style: $settings.style) }.formStyle(.grouped)
            }.tabItem { Label("Subtitles", systemImage: "captions.bubble") }
        }.padding(12).frame(width: 610, height: 570)
            .task { refresh(includeDownloads: false) }
            .alert("Download failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
    private func refresh(includeDownloads: Bool) {
        Task { found = await Task.detached { ModelManager.discover(includeDownloads: includeDownloads) }.value }
    }
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.modelPath = url.path
            refresh(includeDownloads: false)
        }
    }
    private func download() {
        downloading = true
        progress = 0
        Task {
            do {
                let url = try await manager.download(name: modelName) { value in Task { @MainActor in progress = value }
                }
                settings.modelPath = url.path
                refresh(includeDownloads: false)
            } catch { if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription } }
            downloading = false
        }
    }
}
struct SubtitleStyleControls: View {
    @Binding var style: SubtitleStyle
    var body: some View {
        Toggle("Replace inner punctuation with spaces", isOn: $style.replaceInnerPunctuationWithSpaces)
        TextField("Font", text: $style.fontName)
        HStack {
            Text("Size")
            Slider(value: $style.fontSize, in: 16...96, step: 1)
            Text("\(Int(style.fontSize))").monospacedDigit().frame(width: 28)
        }
        TextField("Color (hex)", text: $style.colorHex)
        HStack {
            Text("Outline")
            Slider(value: $style.outline, in: 0...6, step: 0.5)
            Text(String(format: "%.1f", style.outline)).frame(width: 28)
        }
        HStack {
            Text("Bottom margin")
            Slider(value: $style.bottomMargin, in: 0...200, step: 2)
            Text("\(Int(style.bottomMargin))").frame(width: 28)
        }
        Stepper("CJK line length: \(style.cjkLineLength)", value: $style.cjkLineLength, in: 8...30)
        Stepper("Latin line length: \(style.latinLineLength)", value: $style.latinLineLength, in: 20...70)
    }
}
