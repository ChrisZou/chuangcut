import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Native transparent subtitle frames; no libass or drawtext dependency.
public enum SubtitleRenderer {
    public static func render(text: String, style: SubtitleStyle, width: Int, height: Int, to url: URL) throws {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ChuangCutError.message("Cannot allocate subtitle canvas") }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let rgb = UInt32(style.colorHex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFFFFF
        let color = CGColor(
            red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
        let font = CTFontCreateWithName(style.fontName as CFString, max(8, style.fontSize), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let lines = text.components(separatedBy: "\n")
        for (i, text) in lines.enumerated() where !text.isEmpty {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let x = (Double(width) - bounds.width) / 2 - bounds.minX
            let y = max(0, style.bottomMargin) + Double(lines.count - i - 1) * style.fontSize * 1.35 - bounds.minY
            context.textPosition = CGPoint(x: x, y: y)
            context.setLineJoin(.round)
            context.setLineWidth(max(0, style.outline) * 2)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.95))
            context.setFillColor(color)
            context.setTextDrawingMode(style.outline > 0 ? .fillStroke : .fill)
            CTLineDraw(line, context)
            context.textPosition = CGPoint(x: x, y: y)
            context.setTextDrawingMode(.fill)
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ChuangCutError.message("Cannot write subtitle PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) { throw ChuangCutError.message("Subtitle PNG write failed") }
    }
    public static func makeSequence(
        cues: [SubtitleCue], style: SubtitleStyle, width: Int, height: Int, duration: Double, directory: URL,
        cancellation: CancellationToken
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try render(
            text: "", style: style, width: width, height: height, to: directory.appendingPathComponent("blank.png"))
        var script = "ffconcat version 1.0\n"
        var cursor = 0.0
        func append(_ file: String, _ span: Double) {
            guard span > 0.00001 else { return }
            script += "file '\(file)'\noption framerate 1000\nduration \(String(format: "%.6f", span))\n"
        }
        for (i, cue) in cues.enumerated() {
            try cancellation.check()
            if cue.start > cursor { append("blank.png", cue.start - cursor) }
            let name = "cue-\(i).png"
            try render(
                text: cue.text, style: style, width: width, height: height, to: directory.appendingPathComponent(name))
            append(name, cue.end - cue.start)
            cursor = cue.end
        }
        append("blank.png", max(0, duration - cursor))
        // A transparent sentinel terminates the previous image's duration and avoids a frozen final cue.
        script += "file 'blank.png'\noption framerate 1000\n"
        let url = directory.appendingPathComponent("subs.ffconcat")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
