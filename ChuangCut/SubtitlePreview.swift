import SwiftUI
import ChuangCutCore

struct SubtitlePreview: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var thumbnails: ThumbnailStore
    var style: SubtitleStyle
    @State private var overlay: NSImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color(white: 0.1)
                if let poster = thumbnails.poster { Image(nsImage: poster).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                if let overlay { Image(nsImage: overlay).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom).clipped() }
            }
        }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Subtitle style preview over video")
            .onAppear(perform: render).onChange(of: style) { _, _ in render() }.onChange(of: model.revision) { _, _ in render() }
    }
    private func render() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chuangcut-preview-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let project = model.project
        let cues = SubtitleBuilder(style: style).build(words: project?.transcript?.words ?? [], mapper: model.mapper, fillers: project?.candidates.filter { $0.kind == .filler } ?? [])
        do {
            try SubtitleRenderer.render(text: cues.first?.text ?? "字幕预览 Subtitle preview", style: style, width: project?.media.width ?? 1280, height: project?.media.height ?? 720, to: url)
            if let data = try? Data(contentsOf: url) { overlay = NSImage(data: data) }
        } catch { overlay = nil }
    }
}
