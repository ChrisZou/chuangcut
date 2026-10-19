import AppKit
import ChuangCutCore

/// Header controls above the timeline canvas. The canvas has separate observers for its structure,
/// plain redraws and the playhead, so playback never rebuilds clips.
final class TimelinePanel: NSView {
    private let model: EditorModel
    private let canvas = TimelineCanvas()
    private let mode = NSTextField.label(9, weight: .semibold, color: .secondaryLabelColor)
    private let showRemoved = NSButton(checkboxWithTitle: "Show removed", target: nil, action: nil)
    private let zoom = NSSlider()
    private var observers: [Observer] = []
    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        let scroll = TimelineScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        canvas.model = model
        canvas.scroll = scroll
        scroll.documentView = canvas
        canvas.setAccessibilityLabel(
            "Video timeline. Select a clip, drag its edges to trim. Delete removes a selected clip.")

        let icon = NSImageView(image: .symbol("rectangle.stack", "Timeline", size: 11))
        let title = NSTextField.label(12, weight: .semibold)
        title.stringValue = "Timeline"
        showRemoved.font = .systemFont(ofSize: 10)
        showRemoved.target = self
        showRemoved.action = #selector(toggleRemoved)
        // Logarithmic so both a whole long video and frame-level detail are reachable.
        zoom.minValue = log(EditorModel.zoomRange.lowerBound)
        zoom.maxValue = log(EditorModel.zoomRange.upperBound)
        zoom.isContinuous = true
        zoom.target = self
        zoom.action = #selector(zoomChanged)
        zoom.setAccessibilityLabel("Timeline zoom")
        func button(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: .symbol(symbol, help), target: self, action: action)
            button.isBordered = false
            button.toolTip = help
            return button
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let divider = separator(vertical: true)
        let controls = NSStackView(views: [
            icon, title, mode, spacer, showRemoved, divider,
            button("minus.magnifyingglass", "Zoom out", #selector(zoomOut)), zoom,
            button("plus.magnifyingglass", "Zoom in", #selector(zoomIn)),
            button("arrow.left.and.right.righttriangle.left.righttriangle.right", "Fit timeline", #selector(fit)),
        ])
        controls.spacing = 12
        controls.setCustomSpacing(6, after: icon)
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        let header = barBackground()
        header.addFilling(controls)
        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            zoom.widthAnchor.constraint(equalToConstant: 110),
            divider.heightAnchor.constraint(equalToConstant: 16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 190),
        ])
        observers = [
            Observer { [weak self] in
                guard let self else { return }
                mode.attributedStringValue = NSAttributedString(
                    string: model.showRemoved ? "SOURCE" : "EDITED",
                    attributes: [.kern: 1, .font: mode.font as Any, .foregroundColor: NSColor.secondaryLabelColor])
                showRemoved.state = model.showRemoved ? .on : .off
                zoom.doubleValue = log(model.pointsPerSecond)
            },
            Observer { [weak self] in self?.canvas.update() },
            Observer { [weak self] in
                guard let self else { return }
                _ = (model.selectedSegment, model.peaks.count, model.thumbnails.generation)
                canvas.needsDisplay = true
            },
            Observer { [weak self] in
                guard let self else { return }
                canvas.setPlayhead(model.playhead, playing: model.isPlaying)
            },
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleRemoved() { model.showRemoved = showRemoved.state == .on }
    @objc private func zoomChanged() { model.pointsPerSecond = EditorModel.clampZoom(exp(zoom.doubleValue)) }
    @objc private func zoomOut() { model.pointsPerSecond = EditorModel.clampZoom(model.pointsPerSecond / 1.25) }
    @objc private func zoomIn() { model.pointsPerSecond = EditorModel.clampZoom(model.pointsPerSecond * 1.25) }
    @objc private func fit() { canvas.fitToWidth() }
}
final class TimelineScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? TimelineCanvas)?.resizeCanvas()
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let canvas = documentView as? TimelineCanvas {
            canvas.zoom(
                by: exp(Double(event.scrollingDeltaY) * 0.025),
                anchor: canvas.convert(event.locationInWindow, from: nil).x)
            return
        }
        super.scrollWheel(with: event)
    }
}
final class TimelineCanvas: NSView, NSMenuItemValidation {
    weak var model: EditorModel?
    weak var scroll: TimelineScrollView?
    private struct Clip {
        let index: Int
        let source: TimeRange
        let position: Double
    }
    private struct DragState {
        let index: Int
        let edge: TrimEdge
        let source: TimeRange
        let originX: Double
        let lower: Double
        let upper: Double
        let edgeX: Double
        let playhead: Double
    }
    private var clips: [Clip] = []
    private var mapper = TimelineMapper(duration: 0, cuts: [])
    private var pps = 40.0
    private var removed = false
    private var playhead = 0.0
    private var dragState: DragState?
    private var scrubbing = false
    private var lastSeek = 0.0
    private var edgeTime = 0.0
    private var snapX: Double?
    private var tracking: NSTrackingArea?
    private var sourcePath: URL?
    private let inset = 20.0
    private let trackY = 50.0
    private let trackHeight = 100.0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var displayDuration: Double { removed ? mapper.duration : mapper.editedDuration }
    private func x(_ source: Double) -> Double { inset + (removed ? source : mapper.sourceToCut(source)) * pps }
    private func rect(_ clip: Clip) -> NSRect {
        NSRect(
            x: inset + (removed ? clip.source.start : clip.position) * pps, y: trackY,
            width: max(1, clip.source.duration * pps), height: trackHeight)
    }
    /// Clip layout, zoom and source changes. Reads no playhead, so playback does not rerun it.
    func update() {
        guard let model else { return }
        let oldPPS = pps
        let anchorOffset = x(playhead) - visibleRect.minX
        mapper = model.mapper
        removed = model.showRemoved
        var cursor = 0.0
        clips = mapper.keptRanges.enumerated().map { i, range in
            defer { cursor += range.duration }
            return Clip(index: i, source: range, position: cursor)
        }
        pps = model.pointsPerSecond
        if sourcePath != model.project?.source {
            sourcePath = model.project?.source
            scroll?.contentView.scroll(to: .zero)
        }
        resizeCanvas()
        if abs(oldPPS - pps) > 0.001, dragState == nil { scrollTo(x(playhead) - anchorOffset) }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    func setPlayhead(_ time: Double, playing: Bool) {
        playhead = time
        if playing && dragState == nil {
            let head = x(time)
            if head > visibleRect.maxX - 50 || head < visibleRect.minX + 15 { scrollTo(head - 70) }
        }
        needsDisplay = true
    }
    func fitToWidth() {
        guard let scroll else { return }
        model?.pointsPerSecond = EditorModel.clampZoom(
            (scroll.contentSize.width - inset * 2 - 60) / max(1, displayDuration))
    }
    func resizeCanvas() {
        guard let scroll else { return }
        let size = NSSize(
            width: max(scroll.contentSize.width, displayDuration * pps + inset * 2 + 60),
            height: max(165, scroll.contentSize.height))
        if frame.size != size { frame.size = size }
    }
    private func scrollTo(_ position: Double) {
        guard let scroll else { return }
        scroll.contentView.scroll(
            to: NSPoint(x: max(0, min(max(0, bounds.width - scroll.contentSize.width), position)), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, let model else { return }
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let ruler = NSRect(x: dirtyRect.minX, y: 0, width: dirtyRect.width, height: 35)
        NSColor.windowBackgroundColor.withAlphaComponent(0.65).setFill()
        ruler.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: dirtyRect.minX, y: 34, width: dirtyRect.width, height: 0.5).fill()
        drawRuler(in: dirtyRect, context: cg)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: inset, y: trackY, width: max(bounds.width - inset * 2, 1), height: trackHeight),
            xRadius: 7, yRadius: 7
        ).fill()
        var requests: [Double] = []
        for clip in clips {
            let box = rect(clip)
            guard box.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.7, dy: 0), xRadius: 6, yRadius: 6)
            cg.saveGState()
            path.addClip()
            NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.26, alpha: 1).setFill()
            box.fill()
            let tileWidth = 92.0
            let first = max(0, Int((dirtyRect.minX - box.minX) / tileWidth))
            let last = max(first, Int((min(box.maxX, dirtyRect.maxX) - box.minX) / tileWidth))
            for tile in first...last {
                let tileRect = NSRect(x: box.minX + Double(tile) * tileWidth, y: box.minY, width: tileWidth, height: 64)
                let source = min(clip.source.end - 0.001, clip.source.start + Double(tile) * tileWidth / pps)
                requests.append(source)
                if let image = model.thumbnails.image(at: source), image.size.width > 0, image.size.height > 0 {
                    // Center-crop to the tile's aspect so portrait footage is not squashed.
                    let scale = max(tileRect.width / image.size.width, tileRect.height / image.size.height)
                    let crop = NSSize(width: tileRect.width / scale, height: tileRect.height / scale)
                    let from = NSRect(
                        x: (image.size.width - crop.width) / 2, y: (image.size.height - crop.height) / 2,
                        width: crop.width, height: crop.height)
                    image.draw(
                        in: tileRect, from: from, operation: .sourceOver, fraction: 0.88, respectFlipped: true,
                        hints: nil)
                }
            }
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSRect(x: box.minX, y: box.minY, width: box.width, height: 22).fill()
            if box.width > 45 {
                let label = "\(clip.index + 1)  \(model.project?.source.lastPathComponent ?? "Video")"
                drawText(
                    label, at: NSPoint(x: max(box.minX + 16, dirtyRect.minX + 4), y: box.minY + 5), color: .white,
                    size: 10, weight: .medium)
            }
            let wave = NSRect(x: box.minX, y: box.minY + 64, width: box.width, height: 36)
            NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.25, alpha: 1).setFill()
            wave.fill()
            drawWaveform(clip, rect: wave, dirty: dirtyRect, context: cg)
            cg.restoreGState()
            if model.selectedSegment == clip.index {
                NSColor.systemYellow.setStroke()
                path.lineWidth = 2
                path.stroke()
                // Solid 12-point bars clipped to the clip silhouette: rounded outside,
                // square inside, with two dark grip strokes centered on each handle.
                cg.saveGState()
                path.addClip()
                let width = min(12.0, box.width / 2)
                for handleX in [box.minX, box.maxX - width] {
                    let handle = NSRect(x: handleX, y: box.minY, width: width, height: box.height)
                    NSColor.systemYellow.setFill()
                    handle.fill()
                    NSColor.black.withAlphaComponent(0.75).setFill()
                    for dx in [-2.0, 1.0] {
                        NSBezierPath(
                            roundedRect: NSRect(x: handle.midX + dx, y: handle.midY - 8, width: 1, height: 16),
                            xRadius: 0.5, yRadius: 0.5
                        ).fill()
                    }
                }
                cg.restoreGState()
            } else {
                NSColor.white.withAlphaComponent(0.17).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        if removed {
            for cut in model.project?.candidates ?? [] {
                let box = NSRect(
                    x: inset + cut.sourceStart * pps, y: trackY, width: cut.range.duration * pps, height: trackHeight)
                guard box.intersects(dirtyRect) else { continue }
                let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
                cg.saveGState()
                path.addClip()
                if cut.enabled {
                    cut.kind.nsColor.withAlphaComponent(0.15).setFill()
                    box.fill()
                    cg.setStrokeColor(cut.kind.nsColor.withAlphaComponent(0.35).cgColor)
                    cg.setLineWidth(1)
                    var line = max(box.minX, dirtyRect.minX) - trackHeight
                    while line < min(box.maxX, dirtyRect.maxX) {
                        cg.move(to: CGPoint(x: line, y: box.maxY))
                        cg.addLine(to: CGPoint(x: line + trackHeight, y: box.minY))
                        line += 9
                    }
                    cg.strokePath()
                }
                cg.restoreGState()
                cut.kind.nsColor.withAlphaComponent(0.65).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        let head = x(playhead)
        cg.setStrokeColor(NSColor.systemRed.cgColor)
        cg.setLineWidth(1.5)
        cg.move(to: CGPoint(x: head, y: 21))
        cg.addLine(to: CGPoint(x: head, y: bounds.height))
        cg.strokePath()
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: NSRect(x: head - 5, y: 18, width: 10, height: 17), xRadius: 3, yRadius: 3).fill()
        if let snapX {
            cg.setStrokeColor(NSColor.systemYellow.cgColor)
            cg.setLineDash(phase: 0, lengths: [3, 3])
            cg.move(to: CGPoint(x: snapX, y: 35))
            cg.addLine(to: CGPoint(x: snapX, y: bounds.height))
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
        }
        if let drag = dragState {
            let old = drag.edge == .left ? drag.source.start : drag.source.end
            let label = String(format: "%.2fs   %+.2fs", edgeTime, edgeTime - old)
            let box = NSRect(
                x: min(visibleRect.maxX - 155, max(visibleRect.minX + 8, drag.edgeX + (edgeTime - old) * pps - 70)),
                y: 155, width: 145, height: 25)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            drawText(
                label, at: NSPoint(x: box.minX + 10, y: box.minY + 6), color: .textBackgroundColor, size: 11, mono: true
            )
        }
        // Queue only visible time buckets; generation and cache delivery occur asynchronously.
        if !requests.isEmpty {
            let times = requests
            DispatchQueue.main.async { [weak model] in model?.thumbnails.request(times) }
        }
    }
    private func drawWaveform(_ clip: Clip, rect: NSRect, dirty: NSRect, context: CGContext) {
        // One read: every access to an observable property goes through its registrar.
        guard let peaks = model?.peaks, !peaks.isEmpty, mapper.duration > 0 else { return }
        context.setStrokeColor(NSColor(calibratedRed: 0.36, green: 0.85, blue: 0.77, alpha: 0.9).cgColor)
        context.setLineWidth(1)
        let startX = max(rect.minX, dirty.minX)
        let endX = min(rect.maxX, dirty.maxX)
        let perSecond = Double(peaks.count) / mapper.duration
        func bucket(_ x: Double) -> Int {
            max(0, min(peaks.count - 1, Int((clip.source.start + (x - rect.minX) / pps) * perSecond)))
        }
        var px = startX
        while px < endX {
            // Each 2-point column shows the loudest peak it spans, so zooming out never hides speech.
            let first = bucket(px)
            let last = max(first, bucket(min(px + 2, endX)) - 1)
            let amp = max(0.7, Double(peaks[first...last].max() ?? 0) * 14)
            context.move(to: CGPoint(x: px, y: rect.midY - amp))
            context.addLine(to: CGPoint(x: px, y: rect.midY + amp))
            px += 2
        }
        context.strokePath()
    }
    private func drawRuler(in rect: NSRect, context: CGContext) {
        let steps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600.0]
        let step = steps.first { $0 * pps >= 75 } ?? 3600
        let minor = step / 5
        var t = max(0, floor((rect.minX - inset) / pps / minor) * minor)
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(0.5)
        while t <= min(displayDuration, (rect.maxX - inset) / pps + minor) {
            let px = inset + t * pps
            let major = abs(t / step - (t / step).rounded()) < 0.001
            context.move(to: CGPoint(x: px, y: major ? 25 : 30))
            context.addLine(to: CGPoint(x: px, y: 35))
            if major {
                drawText(
                    step < 1
                        ? String(format: "%02d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                        : String(format: "%02d:%02d", Int(t.rounded()) / 60, Int(t.rounded()) % 60),
                    at: NSPoint(x: px + 4, y: 7), color: .secondaryLabelColor, size: 10, mono: true)
            }
            t += minor
        }
        context.strokePath()
    }
    private func drawText(
        _ text: String, at point: NSPoint, color: NSColor, size: Double, weight: NSFont.Weight = .regular,
        mono: Bool = false
    ) {
        text.draw(
            at: point,
            withAttributes: [
                .font: mono
                    ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
            ])
    }
    private func handleRect(_ clip: Clip, edge: TrimEdge) -> NSRect {
        let box = rect(clip)
        return NSRect(
            x: edge == .left ? box.minX - 4 : box.maxX - 12, y: box.minY - 4, width: 16, height: box.height + 8)
    }
    private func handle(at point: NSPoint) -> (Clip, TrimEdge)? {
        var hits: [(clip: Clip, edge: TrimEdge, inside: Bool, distance: Double)] = []
        for clip in clips {
            let box = rect(clip)
            for edge in [TrimEdge.left, .right] where handleRect(clip, edge: edge).contains(point) {
                hits.append((clip, edge, box.contains(point), abs(point.x - (edge == .left ? box.minX : box.maxX))))
            }
        }
        // At butted joins, the side under the pointer wins, including unselected clips.
        guard
            let hit = hits.min(by: {
                if $0.inside != $1.inside { return $0.inside }
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                return $0.clip.index == model?.selectedSegment && $1.clip.index != model?.selectedSegment
            })
        else { return nil }
        return (hit.clip, hit.edge)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        for clip in clips where rect(clip).intersects(visibleRect) {
            for edge in [TrimEdge.left, .right] {
                addCursorRect(handleRect(clip, edge: edge), cursor: .resizeLeftRight)
            }
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if removed, let cut = model?.project?.candidates.first(where: { $0.range.contains((point.x - inset) / pps) }) {
            toolTip =
                "\(cut.kind.title) · \(String(format: "%.2f–%.2fs", cut.sourceStart, cut.sourceEnd)) · ⌥ click to toggle"
        } else if let clip = clips.first(where: { rect($0).contains(point) }) {
            toolTip =
                "Clip \(clip.index + 1) · \(String(format: "%.2f–%.2fs", clip.source.start, clip.source.end)) · Drag edges to trim"
        } else {
            toolTip = "Click or drag to scrub · ⌘ scroll to zoom"
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let model, !model.busy else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if removed && event.modifierFlags.contains(.option),
            let cut = model.project?.candidates.first(where: { $0.range.contains((point.x - inset) / pps) })
        {
            model.toggle(cut.id)
            return
        }
        if let (clip, edge) = handle(at: point) {
            let index = clip.index
            let box = rect(clip)
            model.selectedSegment = index
            model.selectedCandidate = nil
            let lower =
                edge == .left
                ? (index > 0 ? clips[index - 1].source.end : 0) : clip.source.start + min(0.1, clip.source.duration)
            let upper =
                edge == .right
                ? (index + 1 < clips.count ? clips[index + 1].source.start : mapper.duration)
                : clip.source.end - min(0.1, clip.source.duration)
            dragState = DragState(
                index: index, edge: edge, source: clip.source, originX: point.x, lower: lower, upper: upper,
                edgeX: edge == .left ? box.minX : box.maxX, playhead: model.playhead)
            edgeTime = edge == .left ? clip.source.start : clip.source.end
            model.beginTrim()
            return
        }
        if let clip = clips.first(where: { rect($0).contains(point) }) {
            model.selectedSegment = clip.index
            model.selectedCandidate = nil
            if event.clickCount == 2 {
                model.pause()
                model.seek(clip.source.start)
                model.togglePlayback()
            } else {
                scrubbing = true
                model.pause()
                scrub(point, force: true)
            }
        } else {
            if point.y > 35 { model.selectedSegment = nil }
            scrubbing = true
            model.pause()
            scrub(point, force: true)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let drag = dragState, let model {
            let old = drag.edge == .left ? drag.source.start : drag.source.end
            var proposed = max(drag.lower, min(drag.upper, old + (point.x - drag.originX) / pps))
            snapX = nil
            if model.snapping && !event.modifierFlags.contains(.command),
                let snapped = TimelineEditor.snap(
                    proposed, words: model.project?.transcript?.words ?? [],
                    extra: [drag.playhead, drag.lower, drag.upper], tolerance: 8 / pps), snapped >= drag.lower,
                snapped <= drag.upper
            {
                proposed = snapped
                snapX = drag.edgeX + (snapped - old) * pps
            }
            edgeTime = proposed
            model.trim(segment: drag.index, edge: drag.edge, time: proposed)
            seek(proposed, force: false)
            if point.x > visibleRect.maxX - 20 { scrollTo(visibleRect.minX + 12) }
            if point.x < visibleRect.minX + 20 { scrollTo(visibleRect.minX - 12) }
            needsDisplay = true
        } else if scrubbing {
            scrub(point, force: false)
        }
    }
    override func mouseUp(with event: NSEvent) {
        if dragState != nil {
            model?.endTrim()
            seek(edgeTime, force: true)
            dragState = nil
            snapX = nil
            needsDisplay = true
        }
        if scrubbing {
            scrub(convert(event.locationInWindow, from: nil), force: true)
            scrubbing = false
        }
    }
    private func scrub(_ point: NSPoint, force: Bool) {
        let time = max(0, min(displayDuration, (point.x - inset) / pps))
        seek(removed ? time : mapper.cutToSource(time), force: force)
    }
    private func seek(_ time: Double, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - lastSeek >= 1 / 30 {
            lastSeek = now
            model?.seek(time)
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            model?.selectedSegment = nil
            needsDisplay = true
        } else if event.keyCode == 51 || event.keyCode == 117 {
            model?.deleteSelectedClip()
        } else {
            super.keyDown(with: event)
        }
    }
    /// Menu commands with plain Delete and Escape shortcuts. They are only in the responder chain
    /// while the timeline has focus, so the same keys still edit text elsewhere.
    @objc func removeSelectedClip(_ sender: Any?) { model?.deleteSelectedClip() }
    @objc func deselectClip(_ sender: Any?) {
        model?.selectedSegment = nil
        needsDisplay = true
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard window?.isKeyWindow == true, let model, model.selectedSegment != nil else { return false }
        return item.action != #selector(removeSelectedClip(_:)) || !model.busy
    }
    override func magnify(with event: NSEvent) {
        zoom(by: max(0.1, 1 + Double(event.magnification)), anchor: convert(event.locationInWindow, from: nil).x)
    }
    func zoom(by factor: Double, anchor: Double) {
        guard let model else { return }
        let offset = anchor - visibleRect.minX
        let time = (anchor - inset) / pps
        let value = EditorModel.clampZoom(pps * factor)
        pps = value
        model.pointsPerSecond = value
        resizeCanvas()
        scrollTo(inset + time * value - offset)
        needsDisplay = true
    }
}
