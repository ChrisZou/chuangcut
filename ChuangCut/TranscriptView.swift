import SwiftUI
import AppKit
import ChuangCutCore

extension CutKind {
    var tint: Color { Color(nsColor: nsColor) }
    var nsColor: NSColor { switch self { case .pause: return .systemBlue; case .filler: return .systemOrange; case .retake: return .systemRed; case .manual: return .systemPurple } }
    var symbol: String { switch self { case .pause: return "pause.fill"; case .filler: return "ellipsis.bubble"; case .retake: return "arrow.uturn.backward"; case .manual: return "scissors" } }
    var title: String { rawValue.capitalized }
}
private extension NSAttributedString.Key {
    static let cutID = NSAttributedString.Key("ChuangCutCandidate")
    static let cutBackground = NSAttributedString.Key("ChuangCutBackground")
    static let pausePill = NSAttributedString.Key("ChuangCutPause")
}
private final class RoundedLayoutManager: NSLayoutManager {
    var active: NSRange?
    var clipSelection: [NSRange] = []
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        func rounded(_ range: NSRange, _ color: NSColor, outline: Bool = false) {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { return }
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1.5, dy: 1)
                let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                if outline { color.setStroke(); path.lineWidth = 1; path.stroke() } else { color.setFill(); path.fill() }
            }
        }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.cutBackground, in: chars) { value, range, _ in if let color = value as? NSColor { rounded(range, color) } }
        for range in clipSelection { rounded(range, NSColor.controlAccentColor.withAlphaComponent(0.10)) }
        if let active { rounded(active, NSColor.controlAccentColor.withAlphaComponent(0.24)) }
    }
}
private final class PauseCell: NSTextAttachmentCell {
    let label: String
    let cutEnabled: Bool
    init(label: String, enabled: Bool) { self.label = label; self.cutEnabled = enabled; super.init(textCell: "") }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize { NSSize(width: (label as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)]).width + 20, height: 22) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -5) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.systemBlue.withAlphaComponent(cutEnabled ? 0.11 : 0.035).setFill(); path.fill()
        NSColor.systemBlue.withAlphaComponent(cutEnabled ? 0.18 : 0.1).setStroke(); path.lineWidth = 0.7; path.stroke()
        (label as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.systemBlue.withAlphaComponent(cutEnabled ? 1 : 0.45)])
    }
}
struct TranscriptView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let layout = RoundedLayoutManager(); layout.addTextContainer(container)
        let storage = NSTextStorage(); storage.addLayoutManager(layout)
        let text = TranscriptTextView(frame: .zero, textContainer: container)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        container.widthTracksTextView = true; container.lineFragmentPadding = 0
        text.textContainerInset = NSSize(width: 70, height: 20)
        text.setAccessibilityLabel("Transcript. Click words to select a clip; select text and press Delete to cut.")
        scroll.documentView = text; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? TranscriptTextView else { return }
        text.onFocus = { model.timelineFocused = false }; text.onSeek = model.seekWord; text.onToggle = model.toggle; text.onManual = model.manualCut
        if text.revision != model.revision { text.rebuild(project: model.project, revision: model.revision) }
        text.highlight(time: model.playhead, clip: model.selectedRange)
    }
}
final class TranscriptTextView: NSTextView {
    var revision = -1
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    var onSeek: ((Double) -> Void)?
    var onToggle: ((UUID) -> Void)?
    var onManual: (([Word]) -> Void)?
    private var wordRanges: [(Word, NSRange)] = []
    private var timestamps: [(Int, Double)] = []
    private var active: NSRange?
    private var selectedClip: TimeRange?
    private var contextCut: UUID?
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        guard let manager = layoutManager, let container = textContainer else { return }
        NSColor.separatorColor.withAlphaComponent(0.5).setFill(); NSRect(x: 54, y: dirtyRect.minY, width: 0.5, height: dirtyRect.height).fill()
        for (index, time) in timestamps where index < (textStorage?.length ?? 0) {
            let glyph = manager.glyphIndexForCharacter(at: index)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = rect.minY + textContainerOrigin.y + 5
            if y + 16 >= dirtyRect.minY && y <= dirtyRect.maxY {
                String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60).draw(at: NSPoint(x: 13, y: y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
            }
        }
        _ = container
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize.width = max(80, newSize.width - 90)
    }
    func rebuild(project: Project?, revision: Int) {
        self.revision = revision; active = nil; selectedClip = nil; wordRanges = []; timestamps = []
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 9; paragraph.paragraphSpacing = 23
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let pauses = (project?.candidates ?? []).filter { $0.kind == .pause }.sorted { $0.sourceStart < $1.sourceStart }
        var pauseIndex = 0
        func pill(_ cut: CutCandidate) {
            let attachment = NSTextAttachment(); attachment.attachmentCell = PauseCell(label: String(format: "Ⅱ %.1fs", cut.range.duration), enabled: cut.enabled)
            let text = NSMutableAttributedString(attachment: attachment)
            text.addAttributes([.cutID: cut.id.uuidString, .pausePill: true, .paragraphStyle: paragraph], range: NSRange(location: 0, length: text.length))
            result.append(text); result.append(NSAttributedString(string: " ", attributes: base))
        }
        for segment in project?.transcript?.segments ?? [] {
            timestamps.append((result.length, segment.start))
            for word in segment.words {
                while pauseIndex < pauses.count && pauses[pauseIndex].sourceStart < word.start { pill(pauses[pauseIndex]); pauseIndex += 1 }
                var attributes = base
                if let cut = project?.candidates.filter({ $0.range.contains((word.start + word.end) / 2) }).sorted(by: { $0.enabled && !$1.enabled }).first {
                    attributes[.cutID] = cut.id.uuidString
                    attributes[.foregroundColor] = cut.kind.nsColor.withAlphaComponent(cut.enabled ? 0.9 : 0.55)
                    if cut.enabled {
                        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attributes[.strikethroughColor] = cut.kind.nsColor
                        attributes[.cutBackground] = cut.kind.nsColor.withAlphaComponent(0.08)
                    } else { attributes[.underlineStyle] = NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue }
                }
                let range = NSRange(location: result.length, length: (word.text as NSString).length)
                wordRanges.append((word, range)); result.append(NSAttributedString(string: word.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: base))
        }
        while pauseIndex < pauses.count { pill(pauses[pauseIndex]); pauseIndex += 1 }
        let selection = selectedRange(); textStorage?.setAttributedString(result)
        if NSMaxRange(selection) <= result.length { setSelectedRange(selection) }
        needsDisplay = true
    }
    func highlight(time: Double, clip: TimeRange?) {
        let next = wordRanges.first { !$0.0.isPunctuation && time >= $0.0.start && time < $0.0.end }?.1
        guard next != active || clip != selectedClip else { return }
        active = next; selectedClip = clip
        if let layout = layoutManager as? RoundedLayoutManager {
            layout.active = next
            let ranges = wordRanges.filter { clip?.contains(($0.0.start + $0.0.end) / 2) == true }.map(\.1)
            var merged: [NSRange] = []
            for range in ranges {
                if let last = merged.last, NSMaxRange(last) == range.location { merged[merged.count - 1] = NSUnionRange(last, range) } else { merged.append(range) }
            }
            layout.clipSelection = merged
        }; needsDisplay = true
    }
    private func index(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, !string.isEmpty else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard selectedRange().length == 0, let index = index(at: event), index < (textStorage?.length ?? 0) else { return }
        if let value = textStorage?.attribute(.cutID, at: index, effectiveRange: nil) as? String, let id = UUID(uuidString: value), event.modifierFlags.contains(.option) || textStorage?.attribute(.pausePill, at: index, effectiveRange: nil) != nil { onToggle?(id); return }
        if let word = wordRanges.first(where: { NSLocationInRange(index, $0.1) })?.0 { onSeek?(word.start) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { cutSelection(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let index = index(at: event), index < (textStorage?.length ?? 0), let value = textStorage?.attribute(.cutID, at: index, effectiveRange: nil) as? String {
            contextCut = UUID(uuidString: value); let item = NSMenuItem(title: "Toggle Cut", action: #selector(toggleContextCut), keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: "Cut Selection", action: #selector(cutSelection), keyEquivalent: ""); item.target = self; menu.addItem(item)
            let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""); copy.target = self; menu.addItem(copy)
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func toggleContextCut() { if let contextCut { onToggle?(contextCut) } }
    @objc private func cutSelection() { onManual?(wordRanges.filter { NSIntersectionRange(selectedRange(), $0.1).length > 0 }.map(\.0)) }
}
