import AppKit
import ChuangCutCore
import Combine
import SwiftUI

extension NSToolbarItem.Identifier {
    fileprivate static let importVideo = Self("import")
    fileprivate static let transcribe = Self("transcribe")
    fileprivate static let detect = Self("detect")
    fileprivate static let preview = Self("preview")
    fileprivate static let snap = Self("snap")
    fileprivate static let split = Self("split")
    fileprivate static let export = Self("export")
}

/// The editor window: toolbar, split layout, sheets and alerts. Panels observe the model themselves.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation
{
    private let model: EditorModel
    private let root = NSViewController()
    private let dropView = DropTargetView()
    private let contentHost = NSView()
    private let processing = ProcessingBar()
    private lazy var processingHeight = processing.heightAnchor.constraint(equalToConstant: 0)
    private let empty: EmptyStateView
    private let split = NSSplitViewController()
    private let inner = NSSplitViewController()
    private var dividersPlaced = false
    private var tools: [NSToolbarItem.Identifier: NSButton] = [:]
    private var observers: [Observer] = []
    private var exportSheet: NSViewController?
    private var showingError = false
    /// Handed to the window while analysis runs, so ⌘Z cannot race the result that replaces the cuts.
    private let inactiveUndoManager = UndoManager()

    init(model: EditorModel) {
        self.model = model
        empty = EmptyStateView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        buildLayout()
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1500, height: 940))
        window.contentMinSize = NSSize(width: 1160, height: 760)
        window.toolbarStyle = .unified
        window.toolbar = makeToolbar()
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("EditorWindow")
        observers = [
            Observer { [weak self] in self?.showContent() },
            Observer { [weak self] in self?.updateTitle() },
            Observer { [weak self] in self?.updateToolbar() },
            Observer { [weak self] in self?.updateProcessing() },
            Observer { [weak self] in self?.updatePresentation() },
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildLayout() {
        root.view = dropView
        dropView.canAccept = { [weak self] in self?.model.busy == false }
        dropView.onDrop = { [weak self] url in self?.model.open(url) }
        processing.onCancel = { [weak self] in self?.model.cancel() }
        for view in [contentHost, processing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            dropView.addSubview(view, positioned: .below, relativeTo: nil)
        }
        NSLayoutConstraint.activate([
            contentHost.topAnchor.constraint(equalTo: dropView.topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: processing.topAnchor),
            processing.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            processing.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            processing.bottomAnchor.constraint(equalTo: dropView.bottomAnchor), processingHeight,
        ])

        let player = PlayerPanel(model: model)
        let transcript = TranscriptPanel(model: model)
        let playerItem = NSSplitViewItem(viewController: controller(player))
        playerItem.minimumThickness = 430
        playerItem.holdingPriority = .init(250)
        let transcriptItem = NSSplitViewItem(viewController: controller(transcript))
        transcriptItem.minimumThickness = 340
        transcriptItem.holdingPriority = .init(260)
        inner.splitView.dividerStyle = .thin
        inner.addSplitViewItem(playerItem)
        inner.addSplitViewItem(transcriptItem)

        let timeline = TimelinePanel(model: model)
        let column = NSView()
        let line = separator()
        for view in [inner.view, line, timeline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            inner.view.topAnchor.constraint(equalTo: column.topAnchor),
            line.topAnchor.constraint(equalTo: inner.view.bottomAnchor),
            timeline.topAnchor.constraint(equalTo: line.bottomAnchor),
            timeline.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        let content = controller(column)
        content.addChild(inner)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 830
        contentItem.holdingPriority = .init(250)

        let sidebarItem = NSSplitViewItem(viewController: controller(MediaSidebar(model: model)))
        sidebarItem.minimumThickness = 230
        sidebarItem.maximumThickness = 300
        sidebarItem.holdingPriority = .init(260)
        split.splitView.dividerStyle = .thin
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        root.addChild(split)
    }
    private func controller(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    // MARK: Model observation

    private func showContent() {
        let editor = model.hasProject
        let target: NSView = editor ? split.view : empty
        if !editor { empty.refresh() }
        guard target.superview !== contentHost else { return }
        for view in contentHost.subviews { view.removeFromSuperview() }
        contentHost.addFilling(target)
        if editor && !dividersPlaced {
            dividersPlaced = true
            window?.layoutIfNeeded()
            split.splitView.setPosition(260, ofDividerAt: 0)
            inner.splitView.setPosition(inner.splitView.bounds.width - 410, ofDividerAt: 0)
        }
    }
    private func updateTitle() {
        guard let window else { return }
        let title = model.project?.source.lastPathComponent ?? "ChuangCut"
        let subtitle = model.project == nil ? "" : "\(timeLabel(model.mapper.editedDuration)) edited"
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }
    private func updateToolbar() {
        let ready = model.hasProject && !model.busy
        tools[.importVideo]?.isEnabled = !model.busy
        tools[.transcribe]?.isEnabled = ready
        tools[.detect]?.isEnabled = ready && model.project?.transcript != nil
        tools[.split]?.isEnabled = ready
        tools[.export]?.isEnabled = ready
        for (id, on) in [(NSToolbarItem.Identifier.preview, model.previewCuts), (.snap, model.snapping)] {
            tools[id]?.state = on ? .on : .off
            tools[id]?.contentTintColor = on ? .controlAccentColor : nil
        }
    }
    private func updateProcessing() {
        let busy = model.busy
        processing.isHidden = !busy
        processingHeight.constant = busy ? 44 : 0
        processing.update(label: model.progressLabel, progress: model.progress)
    }
    private func updatePresentation() {
        if let message = model.error { showError(message) }
        if model.showExport, model.hasProject, exportSheet == nil {
            let sheet = NSHostingController(rootView: ExportView(model: model))
            sheet.sizingOptions = .preferredContentSize
            exportSheet = sheet
            root.presentAsSheet(sheet)
        } else if !model.showExport, let sheet = exportSheet {
            exportSheet = nil
            root.dismiss(sheet)
        }
    }
    private func showError(_ message: String) {
        guard !showingError, let window else { return }
        showingError = true
        let alert = NSAlert()
        alert.messageText = "ChuangCut"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.showingError = false
            self?.model.error = nil
        }
    }

    // MARK: Commands

    @objc func importVideo(_ sender: Any?) { model.chooseFile() }
    /// Re-transcribing replaces detected cuts, so ask first when there is existing analysis.
    @objc func transcribe(_ sender: Any?) {
        guard model.hasProject, !model.busy else { return }
        guard model.project?.transcript != nil, let window else { return model.transcribe() }
        let alert = NSAlert()
        alert.messageText = "Transcribe again?"
        alert.informativeText =
            "Detected cuts and their trims will be replaced by a new analysis. Manual cuts and splits are kept, "
            + "and you can undo with ⌘Z."
        alert.addButton(withTitle: "Transcribe")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.transcribe() }
        }
    }
    @objc func detect(_ sender: Any?) { model.detect() }
    @objc func togglePreview(_ sender: Any?) { model.previewCuts.toggle() }
    @objc func toggleSnap(_ sender: Any?) { model.snapping.toggle() }
    @objc func splitAtPlayhead(_ sender: Any?) { model.splitAtPlayhead() }
    @objc func showExport(_ sender: Any?) {
        guard model.hasProject, !model.busy else { return }
        model.showExport = true
    }
    @objc func togglePlayback(_ sender: Any?) { model.togglePlayback() }
    @objc func skipBackward(_ sender: Any?) { model.skip(-5) }
    @objc func skipForward(_ sender: Any?) { model.skip(5) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // A sheet or another window is taking input; plain-key shortcuts such as Space must pass through.
        guard window?.isKeyWindow == true else { return false }
        switch item.action {
        case #selector(togglePlayback(_:)):
            item.title = model.isPlaying ? "Pause" : "Play"
            return model.hasProject && !model.busy
        case #selector(skipBackward(_:)), #selector(skipForward(_:)): return model.hasProject
        case #selector(importVideo(_:)): return !model.busy
        default: return model.hasProject && !model.busy
        }
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.busy ? inactiveUndoManager : model.editUndoManager
    }

    // MARK: Toolbar

    private func makeToolbar() -> NSToolbar {
        func tool(
            _ id: NSToolbarItem.Identifier, _ title: String, _ symbol: String, _ action: Selector,
            help: String? = nil, toggle: Bool = false
        ) {
            let button = NSButton(title: title, image: .symbol(symbol, title), target: self, action: action)
            button.bezelStyle = .toolbar
            button.imagePosition = toggle ? .imageOnly : .imageLeading
            if toggle { button.setButtonType(.pushOnPushOff) }
            button.toolTip = help ?? title
            tools[id] = button
        }
        tool(.importVideo, "Import", "plus", #selector(importVideo(_:)))
        tool(.transcribe, "Transcribe", "text.bubble", #selector(transcribe(_:)))
        tool(.detect, "Detect", "wand.and.stars", #selector(detect(_:)))
        tool(
            .preview, "Preview", "play.rectangle", #selector(togglePreview(_:)),
            help: "Skip enabled cuts during playback",
            toggle: true)
        tool(
            .snap, "Snap", "align.horizontal.center", #selector(toggleSnap(_:)),
            help: "Snap trim edges · hold ⌘ to bypass", toggle: true)
        tool(.split, "Split", "scissors", #selector(splitAtPlayhead(_:)))
        tool(.export, "Export", "square.and.arrow.up", #selector(showExport(_:)))
        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.importVideo, .flexibleSpace, .transcribe, .detect, .preview, .snap, .split, .export]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let button = tools[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = button.title
        item.toolTip = button.toolTip
        item.autovalidates = false
        return item
    }
}

/// Accepts a dropped video anywhere in the window and outlines the window while a drag hovers.
private final class DropTargetView: NSView {
    var canAccept: () -> Bool = { true }
    var onDrop: (URL) -> Void = { _ in }
    private let highlight = DropHighlight()
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        highlight.isHidden = true
        addFilling(highlight)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(), fileURL(sender) != nil else { return [] }
        highlight.isHidden = false
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight.isHidden = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        guard canAccept(), let url = fileURL(sender) else { return false }
        onDrop(url)
        return true
    }
    private func fileURL(_ info: NSDraggingInfo) -> URL? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .first as? URL
    }
}
private final class DropHighlight: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 7.5, dy: 7.5), xRadius: 12, yRadius: 12)
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

private final class EmptyStateView: NSView {
    private let model: EditorModel
    private let status = NSStackView()
    private var settingsChange: AnyCancellable?
    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        // objectWillChange fires before the new value is stored; read it on the next turn of the run loop.
        settingsChange = AppSettings.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refresh()
        }
        let icon = NSImageView(image: .symbol("film.stack", nil, size: 52, weight: .light))
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField.label(17, weight: .medium)
        title.stringValue = "Drop a video or press ⌘O"
        let button = NSButton(title: "Import video", target: self, action: #selector(importVideo))
        button.controlSize = .large
        button.keyEquivalent = "\r"
        let stack = NSStackView(views: [icon, title, button, status])
        stack.orientation = .vertical
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        for view in status.arrangedSubviews { view.removeFromSuperview() }
        let settings = AppSettings.shared
        if case .success(let engine) = settings.engine {
            let check = NSImageView(image: .symbol("checkmark.circle.fill", nil, size: 10))
            check.contentTintColor = .secondaryLabelColor
            let label = NSTextField.label(10, color: .secondaryLabelColor)
            switch engine {
            case .doubao: label.stringValue = "Transcription: Doubao Seed-ASR"
            case .whisper(let model): label.stringValue = "Model: " + model.deletingPathExtension().lastPathComponent
            }
            status.setViews([check, label], in: .center)
        } else {
            let title = settings.transcriber == .doubao ? "No Doubao API key — Settings" : "No model — Download"
            let link = NSButton(title: title, target: self, action: #selector(openSettings))
            link.isBordered = false
            link.contentTintColor = .linkColor
            status.setViews([link], in: .center)
        }
    }
    @objc private func importVideo() { model.chooseFile() }
    @objc private func openSettings() { model.openSettings() }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 60, dy: 60), xRadius: 20, yRadius: 20)
        NSColor.quaternarySystemFill.setFill()
        path.fill()
        path.lineWidth = 1.5
        path.setLineDash([7, 7], count: 2, phase: 0)
        NSColor.quaternaryLabelColor.setStroke()
        path.stroke()
    }
}

private final class ProcessingBar: NSVisualEffectView {
    var onCancel: () -> Void = {}
    private let spinner = NSProgressIndicator()
    private let label = NSTextField.label(12, weight: .medium)
    private let bar = NSProgressIndicator()
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .headerView
        blendingMode = .withinWindow
        spinner.style = .spinning
        spinner.controlSize = .small
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(
            image: .symbol("xmark.circle.fill", "Cancel processing"), target: self, action: #selector(cancel))
        cancel.isBordered = false
        cancel.toolTip = "Cancel"
        let spacer = NSView()
        let stack = NSStackView(views: [spinner, label, bar, spacer, cancel])
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        let preferredWidth = bar.widthAnchor.constraint(equalToConstant: 260)
        preferredWidth.priority = .defaultLow
        NSLayoutConstraint.activate([bar.widthAnchor.constraint(lessThanOrEqualToConstant: 260), preferredWidth])
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addFilling(stack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isHidden: Bool {
        didSet { isHidden ? spinner.stopAnimation(nil) : spinner.startAnimation(nil) }
    }
    func update(label text: String, progress: Double) {
        label.stringValue = text
        bar.doubleValue = progress
    }
    @objc private func cancel() { onCancel() }
}
