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
    static let wordID = NSAttributedString.Key("ChuangCutWord")
    static let cutID = NSAttributedString.Key("ChuangCutCandidate")
    static let pausePill = NSAttributedString.Key("ChuangCutPause")
}
struct TranscriptView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = TranscriptTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 18, height: 20)
        text.toolTip = "Click a word to seek. Option-click a cut to toggle. Select text and press Delete to cut."
        text.setAccessibilityLabel("Transcript. Select words and press Delete to cut.")
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? TranscriptTextView else { return }
        text.onSeek = model.seek; text.onToggle = model.toggle; text.onManual = model.manualCut
        if text.revision != model.revision { text.rebuild(project: model.project, revision: model.revision) }
        text.highlight(time: model.playhead)
    }
}
final class TranscriptTextView: NSTextView {
    var revision = -1
    var onSeek: ((Double) -> Void)?
    var onToggle: ((UUID) -> Void)?
    var onManual: (([Word]) -> Void)?
    private var wordRanges: [(Word, NSRange)] = []
    private var active: NSRange?
    private var contextCut: UUID?
    func rebuild(project: Project?, revision: Int) {
        self.revision = revision; active = nil; wordRanges = []
        let result = NSMutableAttributedString(string: "")
        let body = NSFont.systemFont(ofSize: 16)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 10; paragraph.paragraphSpacing = 20
        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let pauses = (project?.candidates ?? []).filter { $0.kind == .pause }.sorted { $0.sourceStart < $1.sourceStart }
        var pauseIndex = 0
        func pill(_ cut: CutCandidate) {
            result.append(NSAttributedString(string: "  \(cut.text)  ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: cut.kind.nsColor.withAlphaComponent(cut.enabled ? 1 : 0.4), .backgroundColor: cut.kind.nsColor.withAlphaComponent(0.12), .cutID: cut.id.uuidString, .pausePill: true, .paragraphStyle: paragraph]))
        }
        for segment in project?.transcript?.segments ?? [] {
            result.append(NSAttributedString(string: "\(Self.time(segment.start))  ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph]))
            for word in segment.words {
                while pauseIndex < pauses.count && pauses[pauseIndex].sourceStart < word.start { pill(pauses[pauseIndex]); pauseIndex += 1 }
                var attributes = base; attributes[.wordID] = word.id.uuidString
                if let cut = project?.candidates.filter({ $0.kind != .pause && $0.range.contains((word.start + word.end) / 2) }).sorted(by: { $0.enabled && !$1.enabled }).first {
                    attributes[.cutID] = cut.id.uuidString
                    attributes[.foregroundColor] = cut.kind.nsColor.withAlphaComponent(cut.enabled ? 0.85 : 0.6)
                    if cut.enabled { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attributes[.strikethroughColor] = cut.kind.nsColor }
                    else { attributes[.underlineStyle] = NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue }
                }
                let range = NSRange(location: result.length, length: (word.text as NSString).length)
                wordRanges.append((word, range)); result.append(NSAttributedString(string: word.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: base))
        }
        while pauseIndex < pauses.count { pill(pauses[pauseIndex]); pauseIndex += 1 }
        let selection = selectedRange()
        textStorage?.setAttributedString(result)
        if NSMaxRange(selection) <= result.length { setSelectedRange(selection) }
    }
    func highlight(time: Double) {
        let next = wordRanges.first { !$0.0.isPunctuation && time >= $0.0.start && time < $0.0.end }?.1
        guard next != active else { return }
        if let active { layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: active) }
        if let next { layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22), forCharacterRange: next) }
        active = next
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
        if event.keyCode == 51 || event.keyCode == 117 {
            let selection = selectedRange()
            let words = wordRanges.filter { NSIntersectionRange(selection, $0.1).length > 0 }.map(\.0)
            if !words.isEmpty { onManual?(words) }; return
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let index = index(at: event), index < (textStorage?.length ?? 0), let value = textStorage?.attribute(.cutID, at: index, effectiveRange: nil) as? String {
            contextCut = UUID(uuidString: value)
            let item = NSMenuItem(title: "Toggle Cut", action: #selector(toggleContextCut), keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: "Cut Selection", action: #selector(cutSelection), keyEquivalent: ""); item.target = self; menu.addItem(item)
            let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""); copy.target = self; menu.addItem(copy)
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func toggleContextCut() { if let contextCut { onToggle?(contextCut) } }
    @objc private func cutSelection() { onManual?(wordRanges.filter { NSIntersectionRange(selectedRange(), $0.1).length > 0 }.map(\.0)) }
    static func time(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
