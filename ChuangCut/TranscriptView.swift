import AppKit
import ChuangCutCore

extension CutKind {
    var nsColor: NSColor {
        switch self {
        case .pause: return .systemBlue
        case .filler: return .systemOrange
        case .retake: return .systemRed
        case .manual: return .systemPurple
        }
    }
    var symbol: String {
        switch self {
        case .pause: return "pause.fill"
        case .filler: return "ellipsis.bubble"
        case .retake: return "arrow.uturn.backward"
        case .manual: return "scissors"
        }
    }
    var title: String {
        switch self {
        case .pause: return L10n.CutKind.pause
        case .filler: return L10n.CutKind.filler
        case .retake: return L10n.CutKind.retake
        case .manual: return L10n.CutKind.manual
        }
    }
}
extension NSAttributedString.Key {
    fileprivate static let cutID = NSAttributedString.Key("ChuangCutCandidate")
    fileprivate static let cutBackground = NSAttributedString.Key("ChuangCutBackground")
    fileprivate static let pausePill = NSAttributedString.Key("ChuangCutPause")
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
            enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1.5, dy: 1)
                let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                if outline {
                    color.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                } else {
                    color.setFill()
                    path.fill()
                }
            }
        }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.cutBackground, in: chars) { value, range, _ in
            if let color = value as? NSColor { rounded(range, color) }
        }
        for range in clipSelection { rounded(range, NSColor.controlAccentColor.withAlphaComponent(0.10)) }
        if let active { rounded(active, NSColor.controlAccentColor.withAlphaComponent(0.24)) }
    }
}
private final class PauseCell: NSTextAttachmentCell {
    let label: String
    let cutEnabled: Bool
    init(label: String, enabled: Bool) {
        self.label = label
        self.cutEnabled = enabled
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize {
        NSSize(
            width: (label as NSString).size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            ]).width + 20, height: 22)
    }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -5) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.systemBlue.withAlphaComponent(cutEnabled ? 0.11 : 0.035).setFill()
        path.fill()
        NSColor.systemBlue.withAlphaComponent(cutEnabled ? 0.18 : 0.1).setStroke()
        path.lineWidth = 0.7
        path.stroke()
        (label as NSString).draw(
            at: NSPoint(x: rect.minX + 8, y: rect.minY + 4),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.systemBlue.withAlphaComponent(cutEnabled ? 1 : 0.45),
            ])
    }
}
/// Header, word count and the transcript text. Content and highlight observe the model separately,
/// so the playhead tick never rebuilds the text.
final class TranscriptPanel: ColorView {
    private let model: EditorModel
    private let count = NSTextField.label(11, mono: true, color: .tertiaryLabelColor)
    private let scroll = NSScrollView()
    private let text: TranscriptTextView
    private let transcribe = NSButton(title: L10n.Transcript.transcribe, target: nil, action: nil)
    private var observers: [Observer] = []
    init(model: EditorModel) {
        self.model = model
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let layout = RoundedLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        text = TranscriptTextView(frame: .zero, textContainer: container)
        super.init(.textBackgroundColor)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.allowsUndo = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        // Without an unbounded maxSize the view never grows past its first frame and the transcript can't scroll.
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        text.textContainerInset = NSSize(width: 70, height: 20)
        text.setAccessibilityLabel(L10n.Transcript.accessibility)
        // Dropped videos go to the window, not into the text.
        text.unregisterDraggedTypes()
        text.onSeek = { [weak model] in model?.seekWord($0) }
        text.onToggle = { [weak model] in model?.toggle($0) }
        text.onManual = { [weak model] in model?.manualCut($0) }
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = text
        transcribe.bezelStyle = .push
        transcribe.keyEquivalent = "\r"
        transcribe.target = self
        transcribe.action = #selector(startTranscription)

        let title = NSTextField.label(13, weight: .bold)
        title.stringValue = L10n.Transcript.title
        let hint = NSTextField.label(10, color: .secondaryLabelColor)
        hint.stringValue = L10n.Transcript.hint
        let line = separator()
        for view in [title, count, hint, line, scroll, transcribe] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            line.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            transcribe.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            transcribe.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        observers = [
            Observer { [weak self] in self?.updateContent() },
            Observer { [weak self] in
                guard let self else { return }
                text.highlight(time: model.playhead, clip: model.selectedRange, follow: model.isPlaying)
            },
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateContent() {
        let hasTranscript = model.project?.transcript != nil
        scroll.isHidden = !hasTranscript
        transcribe.isHidden = hasTranscript
        transcribe.isEnabled = !model.busy
        count.stringValue = model.spokenWordCount.map(String.init) ?? ""
        guard text.revision != model.revision else { return }
        // Dragging a trim edge edits on every mouse event; coalesce the full relayout.
        if model.isTrimming {
            text.rebuildSoon(model)
        } else {
            text.rebuild(project: model.project, revision: model.revision)
        }
    }
    @objc private func startTranscription() { model.transcribe() }
}
final class TranscriptTextView: NSTextView {
    var revision = -1
    var onSeek: ((Word) -> Void)?
    var onToggle: ((UUID) -> Void)?
    var onManual: (([Word]) -> Void)?
    private var wordRanges: [(Word, NSRange)] = []
    private var timestamps: [(Int, Double)] = []
    private var active: NSRange?
    private var selectedClip: TimeRange?
    private var highlightTime = 0.0
    private var highlightClip: TimeRange?
    /// Following playback pauses for a few seconds after the user scrolls the transcript.
    private var userScrolled = Date.distantPast
    private var contextCut: UUID?
    private var rebuildPending = false
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        guard let manager = layoutManager, let container = textContainer else { return }
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 54, y: dirtyRect.minY, width: 0.5, height: dirtyRect.height).fill()
        // Only look up visible lines; asking for every timestamp's line would lay out the whole transcript.
        let band = NSRect(
            x: 0, y: dirtyRect.minY - textContainerOrigin.y, width: container.size.width, height: dirtyRect.height)
        let visible = manager.characterRange(
            forGlyphRange: manager.glyphRange(forBoundingRect: band, in: container), actualGlyphRange: nil)
        for (index, time) in timestamps
        where index >= visible.location && index <= NSMaxRange(visible) && index < (textStorage?.length ?? 0) {
            let glyph = manager.glyphIndexForCharacter(at: index)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = rect.minY + textContainerOrigin.y + 5
            if y + 16 >= dirtyRect.minY && y <= dirtyRect.maxY {
                String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60).draw(
                    at: NSPoint(x: 13, y: y),
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])
            }
        }
        _ = container
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize.width = max(80, newSize.width - 90)
    }
    func rebuild(project: Project?, revision: Int) {
        self.revision = revision
        active = nil
        selectedClip = nil
        // Old ranges would point into the replaced text; highlight() below recomputes them.
        (layoutManager as? RoundedLayoutManager)?.active = nil
        (layoutManager as? RoundedLayoutManager)?.clipSelection = []
        wordRanges = []
        timestamps = []
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 23
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let pauses = (project?.candidates ?? []).filter { $0.kind == .pause }.sorted { $0.sourceStart < $1.sourceStart }
        let mapper = project?.mapper ?? TimelineMapper(duration: 0, cuts: [])
        let words = project?.transcript?.words ?? []
        var pausesAtWord: [Int: [CutCandidate]] = [:]
        for (pause, index) in zip(pauses, mapper.pauseInsertionIndices(pauses, words: words)) {
            pausesAtWord[index, default: []].append(pause)
        }
        let wordCuts = mapper.candidates(for: words, cuts: project?.candidates ?? [])
        var wordIndex = 0
        func pill(_ cut: CutCandidate) {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = PauseCell(label: cut.text, enabled: cut.enabled)
            let text = NSMutableAttributedString(attachment: attachment)
            text.addAttributes(
                [.cutID: cut.id.uuidString, .pausePill: true, .paragraphStyle: paragraph],
                range: NSRange(location: 0, length: text.length))
            result.append(text)
            result.append(NSAttributedString(string: " ", attributes: base))
        }
        for segment in project?.transcript?.segments ?? [] {
            timestamps.append((result.length, segment.start))
            for word in segment.words {
                for cut in pausesAtWord[wordIndex] ?? [] { pill(cut) }
                let wordCut = wordCuts[wordIndex]
                wordIndex += 1
                var attributes = base
                if let cut = wordCut {
                    attributes[.cutID] = cut.id.uuidString
                    attributes[.foregroundColor] = cut.kind.nsColor.withAlphaComponent(cut.enabled ? 0.9 : 0.55)
                    if cut.enabled {
                        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                        attributes[.strikethroughColor] = cut.kind.nsColor
                        attributes[.cutBackground] = cut.kind.nsColor.withAlphaComponent(0.08)
                    } else {
                        attributes[.underlineStyle] =
                            NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue
                    }
                }
                let range = NSRange(location: result.length, length: (word.text as NSString).length)
                wordRanges.append((word, range))
                result.append(NSAttributedString(string: word.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: base))
        }
        for cut in pausesAtWord[wordIndex] ?? [] { pill(cut) }
        let selection = selectedRange()
        textStorage?.setAttributedString(result)
        if NSMaxRange(selection) <= result.length { setSelectedRange(selection) }
        highlight(time: highlightTime, clip: highlightClip)
        needsDisplay = true
    }
    func rebuildSoon(_ model: EditorModel) {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak model] in
            guard let self, let model else { return }
            self.rebuildPending = false
            if self.revision != model.revision { self.rebuild(project: model.project, revision: model.revision) }
        }
    }
    func highlight(time: Double, clip: TimeRange?, follow: Bool = false) {
        highlightTime = time
        highlightClip = clip
        let next = wordRanges.first { time >= $0.0.start && time < $0.0.end && !$0.0.isPunctuation }?.1
        guard next != active || clip != selectedClip else { return }
        if follow, let next, next != active, Date().timeIntervalSince(userScrolled) > 3 { reveal(next) }
        active = next
        selectedClip = clip
        if let layout = layoutManager as? RoundedLayoutManager {
            layout.active = next
            let ranges = wordRanges.filter { clip?.contains(($0.0.start + $0.0.end) / 2) == true }.map(\.1)
            var merged: [NSRange] = []
            for range in ranges {
                if let last = merged.last, NSMaxRange(last) == range.location {
                    merged[merged.count - 1] = NSUnionRange(last, range)
                } else {
                    merged.append(range)
                }
            }
            layout.clipSelection = merged
        }
        needsDisplay = true
    }
    /// Keeps the spoken word on screen during playback, a third of the way down so the next lines show.
    private func reveal(_ range: NSRange) {
        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.y += textContainerOrigin.y
        let visible = visibleRect
        guard rect.minY < visible.minY + 20 || rect.maxY > visible.maxY - 20 else { return }
        scroll(NSPoint(x: 0, y: max(0, min(rect.minY - visible.height / 3, bounds.height - visible.height))))
    }
    override func scrollWheel(with event: NSEvent) {
        userScrolled = Date()
        super.scrollWheel(with: event)
    }
    private func index(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, !string.isEmpty else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }
    override func mouseDown(with event: NSEvent) {
        // NSTextView tracks the whole click or drag here and never calls mouseUp(with:); a plain click
        // leaves the selection empty.
        super.mouseDown(with: event)
        guard selectedRange().length == 0, let index = index(at: event), index < (textStorage?.length ?? 0) else {
            return
        }
        if let value = textStorage?.attribute(.cutID, at: index, effectiveRange: nil) as? String,
            let id = UUID(uuidString: value),
            event.modifierFlags.contains(.option)
                || textStorage?.attribute(.pausePill, at: index, effectiveRange: nil) != nil
        {
            onToggle?(id)
            return
        }
        if let word = wordRanges.first(where: { NSLocationInRange(index, $0.1) })?.0 { onSeek?(word) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            cutSelection()
            return
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let index = index(at: event), index < (textStorage?.length ?? 0),
            let value = textStorage?.attribute(.cutID, at: index, effectiveRange: nil) as? String
        {
            contextCut = UUID(uuidString: value)
            let item = NSMenuItem(title: L10n.Transcript.toggleCut, action: #selector(toggleContextCut), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: L10n.Transcript.cutSelection, action: #selector(cutSelection), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let copy = NSMenuItem(title: L10n.Transcript.copy, action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func toggleContextCut() { if let contextCut { onToggle?(contextCut) } }
    @objc private func cutSelection() {
        onManual?(wordRanges.filter { NSIntersectionRange(selectedRange(), $0.1).length > 0 }.map(\.0))
    }
}
