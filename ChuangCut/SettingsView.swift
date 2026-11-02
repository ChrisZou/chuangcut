import ChuangCutCore
import SwiftUI

/// One view per Settings tab; AppKit hosts them in a toolbar-style tab view controller.
struct TranscriptionSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var found: [URL] = []
    @State private var modelName = ModelManager.recommended[0]
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var error: String?
    @State private var manager = ModelManager()
    var body: some View {
        Form {
            Section {
                Picker(L10n.Settings.engine, selection: $settings.transcriber) {
                    Text(L10n.Settings.doubao).tag(Transcriber.doubao)
                    Text(L10n.Settings.whisper).tag(Transcriber.whisper)
                }
            } footer: {
                Text(
                    settings.transcriber == .doubao
                        ? L10n.Settings.doubaoFooter
                        : L10n.Settings.whisperFooter
                ).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if settings.transcriber == .doubao {
                Section {
                    SecureField(L10n.Settings.apiKey, text: $settings.doubaoKey)
                    TextField(L10n.Settings.hotword, text: $settings.hotwordTable, prompt: Text(L10n.Settings.hotwordPrompt))
                } header: {
                    Text(L10n.Settings.doubaoSection)
                } footer: {
                    Link(
                        L10n.Settings.getKey,
                        destination: URL(string: "https://console.volcengine.com/speech/app")!
                    ).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                whisperModel
            }
            Section(L10n.Settings.tools) {
                TextField("ffmpeg", text: $settings.ffmpegPath)
                TextField("whisper-cli", text: $settings.whisperPath)
            }
        }.formStyle(.grouped).frame(width: 610, height: 520)
            .task { refresh(includeDownloads: false) }
            .alert(L10n.Settings.downloadFailed, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L10n.Settings.ok) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
    private var whisperModel: some View {
        Section(L10n.Settings.whisperModel) {
            HStack {
                TextField(L10n.Settings.modelPath, text: $settings.modelPath)
                Button {
                    chooseModel()
                } label: {
                    Image(systemName: "folder")
                }.help(L10n.Settings.chooseModel).accessibilityLabel(L10n.Settings.chooseModel)
            }
            if !found.isEmpty {
                Picker(L10n.Settings.installed, selection: $settings.modelPath) {
                    if !found.contains(where: { $0.path == settings.modelPath }) {
                        Text(
                            settings.modelPath.isEmpty
                                ? L10n.Settings.chooseAModel : URL(fileURLWithPath: settings.modelPath).lastPathComponent
                        ).tag(settings.modelPath)
                    }
                    ForEach(found, id: \.path) { Text($0.lastPathComponent).tag($0.path) }
                }
            }
            Picker(L10n.Settings.download, selection: $modelName) {
                ForEach(ModelManager.recommended, id: \.self) {
                    Text(
                        $0.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")
                    ).tag($0)
                }
            }
            HStack {
                if downloading {
                    ProgressView(value: progress)
                    Button(L10n.Settings.cancel) { manager.cancel() }
                } else {
                    Button(L10n.Settings.download) { download() }
                    Spacer()
                    Button {
                        refresh(includeDownloads: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help(L10n.Settings.findModels)
                }
            }
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
struct DetectionSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Form {
            Picker(L10n.Settings.language, selection: $settings.language) {
                Text("中文").tag("zh")
                Text(L10n.Settings.auto).tag("auto")
                Text("English").tag("en")
                Text("日本語").tag("ja")
                Text("한국어").tag("ko")
                Text("Français").tag("fr")
                Text("Deutsch").tag("de")
                Text("Español").tag("es")
            }
            HStack {
                Text(L10n.Settings.pauseThreshold)
                Slider(value: $settings.pause, in: 0.2...2, step: 0.05)
                Text(String(format: "%.2f s", settings.pause)).monospacedDigit().frame(width: 55)
            }
            Section {
                HStack {
                    Text(L10n.Settings.beforeSpeech)
                    Slider(value: $settings.leadIn, in: 0...0.2, step: 0.01)
                    Text(String(format: "%.2f s", settings.leadIn)).monospacedDigit().frame(width: 55)
                }
                gapSlider(L10n.Settings.pauseAfterSentence, $settings.sentenceGap)
                gapSlider(L10n.Settings.pauseAfterComma, $settings.commaGap)
                gapSlider(L10n.Settings.pauseBetweenWords, $settings.wordGap)
            }
            TextField(L10n.Settings.fillers, text: $settings.fillerText, axis: .vertical).lineLimit(3...5)
        }.formStyle(.grouped).frame(width: 610, height: 520)
    }
    private func gapSlider(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: 0.05...0.8, step: 0.01)
            Text(String(format: "%.2f s", value.wrappedValue)).monospacedDigit().frame(width: 55)
        }
    }
}
struct SubtitleSettingsView: View {
    var model: EditorModel
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        VStack(spacing: 12) {
            SubtitlePreview(model: model, thumbnails: model.thumbnails, style: settings.style).padding(
                .horizontal, 20)
            Form { SubtitleStyleControls(style: $settings.style) }.formStyle(.grouped)
        }.padding(.top, 12).frame(width: 610, height: 520)
    }
}
struct SubtitleStyleControls: View {
    @Binding var style: SubtitleStyle
    var body: some View {
        Toggle(L10n.Settings.replacePunct, isOn: $style.replaceInnerPunctuationWithSpaces)
        TextField(L10n.Settings.font, text: $style.fontName)
        HStack {
            Text(L10n.Settings.size)
            Slider(value: $style.fontSize, in: 16...96, step: 1)
            Text("\(Int(style.fontSize))").monospacedDigit().frame(width: 28)
        }
        TextField(L10n.Settings.colorHex, text: $style.colorHex)
        HStack {
            Text(L10n.Settings.outline)
            Slider(value: $style.outline, in: 0...6, step: 0.5)
            Text(String(format: "%.1f", style.outline)).frame(width: 28)
        }
        HStack {
            Text(L10n.Settings.bottomMargin)
            Slider(value: $style.bottomMargin, in: 0...200, step: 2)
            Text("\(Int(style.bottomMargin))").frame(width: 28)
        }
        Stepper(String(format: L10n.Settings.cjkLine, style.cjkLineLength), value: $style.cjkLineLength, in: 8...30)
        Stepper(String(format: L10n.Settings.latinLine, style.latinLineLength), value: $style.latinLineLength, in: 20...70)
    }
}
