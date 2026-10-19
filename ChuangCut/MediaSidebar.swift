import AppKit
import ChuangCutCore

/// Media summary plus every cut grouped by kind. An edit reloads only the rows whose cut changed.
final class MediaSidebar: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row: Equatable {
        case header(CutKind)
        case cut(UUID)
    }
    private let model: EditorModel
    private let card = MediaCard()
    private let table = NSTableView()
    private var rows: [Row] = []
    private var cuts: [UUID: CutCandidate] = [:]
    private var busy = false
    private var observers: [Observer] = []

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .withinWindow
        let column = NSTableColumn(identifier: .init("cut"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("Sidebar")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let line = separator()
        for view in [card, line, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.heightAnchor.constraint(equalToConstant: MediaCard.height),
            line.topAnchor.constraint(equalTo: card.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observers = [
            Observer { [weak self] in
                guard let self else { return }
                card.update(
                    project: model.project, edited: model.mapper.editedDuration, poster: model.thumbnails.poster)
            },
            Observer { [weak self] in self?.reload() },
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func reload() {
        let candidates = model.project?.candidates ?? []
        var next: [Row] = []
        for kind in CutKind.allCases {
            next.append(.header(kind))
            next += candidates.filter { $0.kind == kind }.map { .cut($0.id) }
        }
        let nextCuts = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if next != rows || model.busy != busy {
            rows = next
            cuts = nextCuts
            busy = model.busy
            table.reloadData()
        } else {
            // Headers show counts, so they reload with any change.
            var changed = IndexSet()
            for (index, row) in rows.enumerated() {
                switch row {
                case .header: changed.insert(index)
                case .cut(let id): if cuts[id] != nextCuts[id] { changed.insert(index) }
                }
            }
            cuts = nextCuts
            table.reloadData(forRowIndexes: changed, columnIndexes: [0])
            table.noteHeightOfRows(withIndexesChanged: changed)
        }
        let selected = model.selectedCandidate.flatMap { rows.firstIndex(of: .cut($0)) }
        if let selected {
            if table.selectedRow != selected { table.selectRowIndexes([selected], byExtendingSelection: false) }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }
    private func cuts(of kind: CutKind) -> [CutCandidate] {
        rows.compactMap { if case .cut(let id) = $0, let cut = cuts[id], cut.kind == kind { cut } else { nil } }
    }
    private var cellWidth: CGFloat { max(120, table.tableColumns[0].width) }

    @objc private func rowClicked() {
        guard rows.indices.contains(table.clickedRow), case .cut(let id) = rows[table.clickedRow], let cut = cuts[id]
        else { return }
        model.selectCandidate(cut)
    }
    @objc private func toggleCut(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard rows.indices.contains(row), case .cut(let id) = rows[row] else { return }
        model.toggle(id)
    }
    @objc private func toggleKind(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard rows.indices.contains(row), case .header(let kind) = rows[row] else { return }
        model.setAll(kind, enabled: sender.state == .on)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { true } else { false }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .cut = rows[row] { true } else { false }
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 30
        case .cut(let id): return cuts[id].map { CutCell.height(for: $0, width: cellWidth) } ?? 44
        }
    }
    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let kind):
            let cell =
                tableView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) as? HeaderCell ?? HeaderCell()
            let all = cuts(of: kind)
            cell.configure(kind, enabled: all.filter(\.enabled).count, total: all.count, busy: busy)
            cell.checkbox.target = self
            cell.checkbox.action = #selector(toggleKind)
            return cell
        case .cut(let id):
            guard let cut = cuts[id] else { return nil }
            let cell = tableView.makeView(withIdentifier: CutCell.identifier, owner: nil) as? CutCell ?? CutCell()
            cell.configure(cut, busy: busy)
            cell.checkbox.target = self
            cell.checkbox.action = #selector(toggleCut)
            return cell
        }
    }
}

private final class HeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("header")
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let badge = KindBadge()
    private let count = NSTextField.label(10, mono: true, color: .secondaryLabelColor)
    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        checkbox.controlSize = .mini
        for view in [badge, count, checkbox] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ kind: CutKind, enabled: Int, total: Int, busy: Bool) {
        badge.configure(kind)
        count.stringValue = "\(enabled)/\(total)"
        checkbox.state = total > 0 && enabled == total ? .on : .off
        checkbox.isEnabled = total > 0 && !busy
        checkbox.toolTip = "Enable / disable all \(kind.title)"
        checkbox.setAccessibilityLabel("\(kind.title), \(enabled)/\(total)")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let size = badge.fittingSize
        badge.frame = NSRect(x: 6, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        count.sizeToFit()
        count.frame.origin = NSPoint(x: badge.frame.maxX + 7, y: (bounds.height - count.frame.height) / 2)
        checkbox.sizeToFit()
        checkbox.frame.origin = NSPoint(
            x: bounds.width - checkbox.frame.width - 4, y: (bounds.height - checkbox.frame.height) / 2)
    }
}

/// Tinted capsule with the kind's symbol and name.
private final class KindBadge: NSView {
    private let background = ColorView(.clear)
    private let icon = NSImageView()
    private let title = NSTextField.label(10, weight: .semibold)
    init() {
        super.init(frame: .zero)
        let stack = NSStackView(views: [icon, title])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7)
        addFilling(background)
        addFilling(stack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ kind: CutKind) {
        icon.image = .symbol(kind.symbol, kind.title, size: 9, weight: .semibold)
        icon.contentTintColor = kind.nsColor
        title.stringValue = kind.title
        title.textColor = kind.nsColor
        background.color = kind.nsColor.withAlphaComponent(0.1)
    }
    override func layout() {
        super.layout()
        background.cornerRadius = bounds.height / 2
    }
}

private final class CutCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("cut")
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let textX: CGFloat = 32
    private static let measure: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.font = font
        cell.wraps = true
        return cell
    }()
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dot = ColorView(.clear, cornerRadius: 2)
    private let range = NSTextField.label(10, weight: .medium, mono: true, color: .secondaryLabelColor)
    private let text = NSTextField(wrappingLabelWithString: "")
    private let adjusted = NSTextField.label(9, weight: .medium)
    private let adjustedBackground = ColorView(.clear, cornerRadius: 7)
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        checkbox.controlSize = .small
        text.font = Self.font
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        adjusted.stringValue = "Adjusted"
        for view in [checkbox, dot, range, text, adjustedBackground, adjusted] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// At most two lines, matching `maximumNumberOfLines`.
    static func textHeight(_ string: String, width: CGFloat) -> CGFloat {
        measure.stringValue = string
        let height = measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height
        measure.stringValue = "A\nA"
        let twoLines = measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height
        return ceil(min(height, twoLines))
    }
    static func height(for cut: CutCandidate, width: CGFloat) -> CGFloat {
        8 + 13 + 6 + textHeight(cut.text, width: width - textX - 8) + (cut.isAdjusted == true ? 21 : 0) + 8
    }
    func configure(_ cut: CutCandidate, busy: Bool) {
        checkbox.state = cut.enabled ? .on : .off
        checkbox.isEnabled = !busy
        checkbox.setAccessibilityLabel("Enable \(cut.text)")
        dot.color = cut.kind.nsColor
        range.stringValue = String(format: "%.2f – %.2f", cut.sourceStart, cut.sourceEnd)
        text.stringValue = cut.text
        text.textColor = cut.enabled ? .labelColor : .secondaryLabelColor
        adjusted.isHidden = cut.isAdjusted != true
        adjustedBackground.isHidden = adjusted.isHidden
        adjusted.textColor = cut.kind.nsColor
        adjustedBackground.color = cut.kind.nsColor.withAlphaComponent(0.1)
        toolTip = cut.reason
        needsLayout = true
    }
    override func layout() {
        super.layout()
        checkbox.sizeToFit()
        checkbox.frame.origin = NSPoint(x: 10, y: 8)
        let x = Self.textX
        let width = max(10, bounds.width - x - 8)
        dot.frame = NSRect(x: x, y: 8 + 4.5, width: 4, height: 4)
        range.frame = NSRect(x: x + 9, y: 8, width: width - 9, height: 13)
        text.frame = NSRect(x: x, y: 8 + 13 + 6, width: width, height: Self.textHeight(text.stringValue, width: width))
        adjusted.sizeToFit()
        adjustedBackground.frame = NSRect(
            x: x, y: text.frame.maxY + 6, width: adjusted.frame.width + 10, height: adjusted.frame.height + 4)
        adjusted.frame.origin = NSPoint(x: x + 5, y: adjustedBackground.frame.minY + 2)
    }
}

/// Poster, file name, durations and time saved.
private final class MediaCard: NSView {
    static let height: CGFloat = 16 + 115 + 12 + 17 + 10 + 15 + 8 + 34 + 12
    private let poster = PosterView()
    private let name = NSTextField.label(13, weight: .semibold)
    private let original = NSTextField.label(12, mono: true, color: .secondaryLabelColor)
    private let arrow = NSImageView(image: .symbol("arrow.right", "to", size: 9))
    private let edited = NSTextField.label(12, weight: .semibold, mono: true)
    private let saved = NSTextField.label(27, weight: .semibold, color: .systemTeal)
    private let percent = NSTextField.label(11, weight: .medium, color: .secondaryLabelColor)
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        name.lineBreakMode = .byTruncatingMiddle
        arrow.contentTintColor = .tertiaryLabelColor
        let base = NSFont.systemFont(ofSize: 27, weight: .semibold)
        saved.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 27) } ?? base
        for view in [poster, name, original, arrow, edited, saved, percent] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(project: Project?, edited editedDuration: Double, poster image: NSImage?) {
        guard let project else { return }
        let media = project.media
        poster.image = image
        poster.caption = "\(media.width) × \(media.height)  ·  \(String(format: "%.0f", media.frameRate ?? 0)) fps"
        name.stringValue = project.source.lastPathComponent
        original.stringValue = timeLabel(media.duration)
        edited.stringValue = timeLabel(editedDuration)
        let removed = media.duration - editedDuration
        saved.attributedStringValue = NSAttributedString(
            string: "−\(String(format: "%.1f", removed))s",
            attributes: [.kern: -1, .font: saved.font as Any, .foregroundColor: NSColor.systemTeal])
        percent.stringValue = "\(Int((removed / max(media.duration, 0.001) * 100).rounded()))% saved"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width - 32
        poster.frame = NSRect(x: 16, y: 16, width: width, height: 115)
        name.frame = NSRect(x: 16, y: poster.frame.maxY + 12, width: width, height: 17)
        let row = name.frame.maxY + 10
        original.sizeToFit()
        original.frame.origin = NSPoint(x: 16, y: row)
        arrow.frame = NSRect(x: original.frame.maxX + 7, y: row + 2, width: 10, height: 11)
        edited.sizeToFit()
        edited.frame.origin = NSPoint(x: arrow.frame.maxX + 7, y: row)
        saved.sizeToFit()
        saved.frame.origin = NSPoint(x: 16, y: row + 15 + 8)
        percent.sizeToFit()
        percent.frame.origin = NSPoint(
            x: bounds.width - 16 - percent.frame.width, y: saved.frame.maxY - percent.frame.height - 6)
    }
}

/// Aspect-filled poster frame with a bottom gradient and a format caption.
private final class PosterView: NSView {
    private static let film = NSImage.symbol("film", nil, size: 10, weight: .medium).withSymbolConfiguration(
        .init(paletteColors: [.white]))
    var image: NSImage? {
        didSet { if image !== oldValue { needsDisplay = true } }
    }
    var caption = "" {
        didSet { if caption != oldValue { needsDisplay = true } }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(
                in: NSRect(
                    x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
                    height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                hints: nil)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            bounds.fill()
        }
        // Flipped, so 90° runs from the middle down to the bottom edge.
        NSGradient(colors: [.clear, .black.withAlphaComponent(0.65)])?.draw(
            in: NSRect(x: 0, y: bounds.midY, width: bounds.width, height: bounds.height / 2), angle: 90)
        Self.film?.draw(
            in: NSRect(x: 10, y: bounds.height - 22, width: 13, height: 11), from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
        (caption as NSString).draw(
            at: NSPoint(x: 28, y: bounds.height - 24),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white])
    }
}
