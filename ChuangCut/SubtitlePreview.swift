import ChuangCutCore
import SwiftUI

struct SubtitlePreview: View {
    var model: EditorModel
    var thumbnails: ThumbnailStore
    var style: SubtitleStyle
    @State private var overlay: NSImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color(white: 0.1)
                if let poster = thumbnails.poster {
                    Image(nsImage: poster).resizable().scaledToFill().frame(
                        width: geometry.size.width, height: geometry.size.height
                    ).clipped()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                if let overlay {
                    Image(nsImage: overlay).resizable().scaledToFill().frame(
                        width: geometry.size.width, height: geometry.size.height, alignment: .bottom
                    ).clipped()
                }
            }
        }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Subtitle style preview over video")
            .onAppear(perform: render).onChange(of: style) { _, _ in render() }.onChange(of: model.cues.first) { _, _ in
                render()
            }
    }
    private func render() {
        let project = model.project
        let cue = project.flatMap {
            SubtitleBuilder(style: style).build(project: $0, mapper: model.mapper, maxCues: 1).first
        }
        // The renderer scales the style with the canvas, so a downscaled canvas looks identical in a
        // 150-point preview and avoids rasterizing a full 4K frame on every slider change.
        let width = Double(project?.media.width ?? 1280)
        let height = Double(project?.media.height ?? 720)
        let scale = min(1, 1280 / max(width, height))
        guard
            let image = try? SubtitleRenderer.image(
                text: cue?.text ?? "字幕预览 Subtitle preview", style: style, width: Int(width * scale),
                height: Int(height * scale))
        else {
            overlay = nil
            return
        }
        overlay = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
