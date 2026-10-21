import ChuangCutCore
import SwiftUI

struct ExportView: View {
    var model: EditorModel
    @State private var output: URL?
    @State private var options = ExportOptions()
    @State private var styleExpanded = false
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Export").font(.title2.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f s", model.mapper.editedDuration)).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Form {
                HStack {
                    Text(output?.path ?? "Choose output file").lineLimit(1).truncationMode(.middle).foregroundStyle(
                        output == nil ? .secondary : .primary)
                    Spacer()
                    Button {
                        chooseOutput()
                    } label: {
                        Image(systemName: "folder")
                    }.help("Choose output file").accessibilityLabel("Choose output file")
                }
                Picker("Quality", selection: $options.quality) {
                    Text("Compact · Hardware").tag(VideoQuality.compact)
                    Text("Balanced · Hardware").tag(VideoQuality.balanced)
                    Text("High · Hardware").tag(VideoQuality.high)
                    Text("H.264 · CRF 20").tag(VideoQuality.software)
                }
                Toggle("Subtitle track", isOn: $options.subtitleTrack)
                    .help("Embed the subtitles as a track players can turn on and off, without burning them in")
                Toggle("SRT file", isOn: $options.includeSRT)
                Toggle("Burn subtitles", isOn: $options.burnSubtitles)
                Button {
                    withAnimation { styleExpanded.toggle() }
                } label: {
                    HStack {
                        Text("Subtitle style")
                        Spacer()
                        Image(systemName: styleExpanded ? "chevron.up" : "chevron.down")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if styleExpanded { SubtitleStyleControls(style: $options.style) }
            }.formStyle(.grouped)
            SubtitlePreview(model: model, thumbnails: model.thumbnails, style: options.style)
            HStack {
                Button("Cancel") { model.showExport = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export") {
                    if output == nil { chooseOutput() }
                    if let output {
                        model.export(to: output, options: options)
                        model.showExport = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 610, height: styleExpanded ? 766 : 566)
            .onAppear { options.style = AppSettings.shared.style }
    }
    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue =
            (model.project?.source.deletingPathExtension().lastPathComponent ?? "video") + "_cut.mp4"
        if panel.runModal() == .OK { output = panel.url }
    }
}
