import SwiftUI
import ChuangCutCore

struct ExportView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var output: URL?
    @State private var options = ExportOptions()
    @State private var preview: NSImage?
    @State private var styleExpanded = false
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text("Export").font(.title2.weight(.semibold)); Spacer(); Text(String(format: "%.1f s", model.mapper.editedDuration)).foregroundStyle(.secondary).monospacedDigit() }
            Form {
                HStack {
                    Text(output?.path ?? "Choose output file").lineLimit(1).truncationMode(.middle).foregroundStyle(output == nil ? .secondary : .primary)
                    Spacer(); Button { chooseOutput() } label: { Image(systemName: "folder") }.help("Choose output file").accessibilityLabel("Choose output file")
                }
                Picker("Quality", selection: $options.quality) {
                    Text("Compact · Hardware").tag(VideoQuality.compact)
                    Text("Balanced · Hardware").tag(VideoQuality.balanced)
                    Text("High · Hardware").tag(VideoQuality.high)
                    Text("H.264 · CRF 20").tag(VideoQuality.software)
                }
                Toggle("SRT file", isOn: $options.includeSRT)
                Toggle("Burn subtitles", isOn: $options.burnSubtitles)
                Button { withAnimation { styleExpanded.toggle() } } label: {
                    HStack { Text("Subtitle style"); Spacer(); Image(systemName: styleExpanded ? "chevron.up" : "chevron.down") }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if styleExpanded { SubtitleStyleControls(style: $options.style) }
            }.formStyle(.grouped)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if let preview { Image(nsImage: preview).resizable().scaledToFill().frame(height: 130, alignment: .bottom).clipped() }
            }.frame(height: 130).accessibilityLabel("Subtitle style preview")
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export") {
                    if output == nil { chooseOutput() }
                    if let output { model.export(to: output, options: options); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 580, height: 660)
        .onAppear { options.style = AppSettings.shared.style; renderPreview() }
        .onChange(of: options.style) { _, _ in renderPreview() }
    }
    private func chooseOutput() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (model.project?.source.deletingPathExtension().lastPathComponent ?? "video") + "_cut.mp4"
        if panel.runModal() == .OK { output = panel.url }
    }
    private func renderPreview() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chuangcut-preview-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let project = model.project, width = project?.media.width ?? 1280, height = project?.media.height ?? 720
        let cues = SubtitleBuilder(style: options.style).build(words: project?.transcript?.words ?? [], mapper: model.mapper, fillers: project?.candidates.filter { $0.kind == .filler } ?? [])
        do {
            try SubtitleRenderer.render(text: cues.first?.text ?? "", style: options.style, width: width, height: height, to: url)
            if let data = try? Data(contentsOf: url) { preview = NSImage(data: data) }
        } catch { preview = nil }
    }
}
