import SwiftUI
import AppKit
import ChuangCutCore

struct TimelineView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> TimelineScrollView {
        let scroll = TimelineScrollView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let canvas = WaveformCanvas(); scroll.documentView = canvas; canvas.scroll = scroll
        canvas.toolTip = "Drag to scrub · Pinch or ⌘ scroll to zoom"
        canvas.setAccessibilityLabel("Video waveform timeline")
        return scroll
    }
    func updateNSView(_ scroll: TimelineScrollView, context: Context) {
        guard let canvas = scroll.documentView as? WaveformCanvas else { return }
        canvas.duration = model.project?.media.duration ?? 0; canvas.peaks = model.peaks
        canvas.cuts = model.mapper.cutRanges; canvas.time = model.playhead; canvas.onSeek = model.seek
        scroll.needsLayout = true; canvas.needsDisplay = true
    }
}
final class TimelineScrollView: NSScrollView {
    override func layout() { super.layout(); if let canvas = documentView as? WaveformCanvas { canvas.frame.size = NSSize(width: max(contentSize.width, contentSize.width * canvas.zoom), height: max(90, contentSize.height)) } }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let canvas = documentView as? WaveformCanvas { canvas.changeZoom(exp(Double(event.scrollingDeltaY) * 0.025), point: convert(event.locationInWindow, from: nil).x); return }
        super.scrollWheel(with: event)
    }
}
final class WaveformCanvas: NSView {
    var duration = 0.0
    var peaks: [Float] = []
    var cuts: [TimeRange] = []
    var time = 0.0
    var zoom = 1.0
    var onSeek: ((Double) -> Void)?
    weak var scroll: TimelineScrollView?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, duration > 0 else { return }
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        let width = bounds.width, height = bounds.height, scale = width / duration
        for cut in cuts {
            let rect = CGRect(x: cut.start * scale, y: 22, width: cut.duration * scale, height: height - 22)
            guard rect.intersects(dirtyRect) else { continue }
            cg.setFillColor(NSColor.systemRed.withAlphaComponent(0.13).cgColor); cg.fill(rect)
            cg.saveGState(); cg.clip(to: rect); cg.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.16).cgColor); cg.setLineWidth(1)
            var x = max(rect.minX, dirtyRect.minX) - height
            while x < min(rect.maxX, dirtyRect.maxX) { cg.move(to: CGPoint(x: x, y: height)); cg.addLine(to: CGPoint(x: x + height, y: 22)); x += 9 }; cg.strokePath(); cg.restoreGState()
        }
        let mid = (height + 22) / 2
        cg.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor); cg.setLineWidth(1.4)
        if !peaks.isEmpty {
            let first = max(0, Int(dirtyRect.minX / width * Double(peaks.count))), last = min(peaks.count, Int(dirtyRect.maxX / width * Double(peaks.count)) + 1)
            for i in first..<max(first, last) {
                let x = Double(i) / Double(peaks.count) * width, amplitude = max(1, Double(peaks[i]) * (height - 38) / 2)
                cg.move(to: CGPoint(x: x, y: mid - amplitude)); cg.addLine(to: CGPoint(x: x, y: mid + amplitude))
            }
            cg.strokePath()
        }
        let step = max(0.5, pow(2, ceil(log2(duration / max(1, width / 85)))))
        var tick = floor(dirtyRect.minX / scale / step) * step
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while tick <= min(duration, dirtyRect.maxX / scale + step) {
            let x = tick * scale
            String(format: "%02d:%04.1f", Int(tick) / 60, tick.truncatingRemainder(dividingBy: 60)).draw(at: NSPoint(x: x + 4, y: 4), withAttributes: attributes)
            tick += step
        }
        let x = time * scale
        cg.setStrokeColor(NSColor.labelColor.cgColor); cg.setLineWidth(1.5); cg.move(to: CGPoint(x: x, y: 22)); cg.addLine(to: CGPoint(x: x, y: height)); cg.strokePath()
        cg.setFillColor(NSColor.labelColor.cgColor); cg.move(to: CGPoint(x: x - 5, y: 20)); cg.addLine(to: CGPoint(x: x + 5, y: 20)); cg.addLine(to: CGPoint(x: x, y: 27)); cg.closePath(); cg.fillPath()
    }
    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }
    private func scrub(_ event: NSEvent) { let point = convert(event.locationInWindow, from: nil); onSeek?(max(0, min(duration, point.x / max(1, bounds.width) * duration))) }
    override func magnify(with event: NSEvent) { changeZoom(1 + Double(event.magnification), point: convert(event.locationInWindow, from: nil).x - visibleRect.minX) }
    func changeZoom(_ factor: Double, point: Double) {
        guard let scroll else { return }
        let oldWidth = max(1, bounds.width), fraction = (visibleRect.minX + point) / oldWidth
        zoom = min(30, max(1, zoom * factor)); scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: max(0, min(bounds.width - scroll.contentSize.width, fraction * bounds.width - point)), y: 0)); scroll.reflectScrolledClipView(scroll.contentView); needsDisplay = true
    }
}
