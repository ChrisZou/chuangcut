import ChuangCutCore
import SwiftUI

struct ExportView: View {
    var model: EditorModel
    @State private var output: URL?
    @State private var options = ExportOptions()
    @State private var styleExpanded = false
    /// An audio recording exports as M4A with its subtitles beside it, so the video options go.
    private var audioOnly: Bool { model.project?.media.isAudioOnly ?? false }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L10n.Export.title).font(.title2.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f s", model.mapper.editedDuration)).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Form {
                HStack {
                    Text(output?.path ?? L10n.Export.chooseOutput).lineLimit(1).truncationMode(.middle).foregroundStyle(
                        output == nil ? .secondary : .primary)
                    Spacer()
                    Button {
                        chooseOutput()
                    } label: {
                        Image(systemName: "folder")
                    }.help(L10n.Export.chooseOutput).accessibilityLabel(L10n.Export.chooseOutput)
                }
                if !audioOnly {
                    Picker(L10n.Export.quality, selection: $options.quality) {
                        Text(L10n.Export.compact).tag(VideoQuality.compact)
                        Text(L10n.Export.balanced).tag(VideoQuality.balanced)
                        Text(L10n.Export.high).tag(VideoQuality.high)
                        Text(L10n.Export.software).tag(VideoQuality.software)
                    }
                    Toggle(L10n.Export.subtitleTrack, isOn: $options.subtitleTrack)
                        .help(L10n.Export.subtitleTrackHelp)
                }
                Toggle(L10n.Export.srt, isOn: $options.includeSRT)
                if !audioOnly { Toggle(L10n.Export.burn, isOn: $options.burnSubtitles) }
                Button {
                    withAnimation { styleExpanded.toggle() }
                } label: {
                    HStack {
                        Text(L10n.Export.style)
                        Spacer()
                        Image(systemName: styleExpanded ? "chevron.up" : "chevron.down")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if styleExpanded { SubtitleStyleControls(style: $options.style) }
            }.formStyle(.grouped)
            SubtitlePreview(model: model, thumbnails: model.thumbnails, style: options.style)
            HStack {
                Button(L10n.Export.cancel) { model.showExport = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.Export.export) {
                    if output == nil { chooseOutput() }
                    if let output {
                        model.export(to: output, options: options)
                        model.showExport = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 610, height: (styleExpanded ? 766 : 566) - (audioOnly ? 104 : 0))
            .onAppear { options.style = AppSettings.shared.style }
    }
    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [audioOnly ? .mpeg4Audio : .mpeg4Movie]
        panel.nameFieldStringValue =
            (model.project?.source.deletingPathExtension().lastPathComponent ?? "video")
            + (audioOnly ? "_cut.m4a" : "_cut.mp4")
        if panel.runModal() == .OK { output = panel.url }
    }
}
