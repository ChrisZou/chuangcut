import AVKit
import ChuangCutCore

/// Video stage plus transport controls. Only the time labels follow the 35 ms playhead tick.
final class PlayerPanel: NSView {
    private let model: EditorModel
    private let stage = PlayerStage()
    private let back: NSButton
    private let play: NSButton
    private let forward: NSButton
    private let editedTime = NSTextField.label(12, weight: .medium, mono: true)
    private let sourceTime = NSTextField.label(10, mono: true, color: .secondaryLabelColor)
    private let previewSwitch = NSSwitch()
    private let reveal: NSButton
    private var observers: [Observer] = []

    init(model: EditorModel) {
        self.model = model
        back = NSButton(image: .symbol("gobackward.5", "Back 5 seconds", size: 15), target: nil, action: nil)
        play = NSButton(image: .symbol("play.fill", "Play", size: 16, weight: .semibold), target: nil, action: nil)
        forward = NSButton(image: .symbol("goforward.5", "Forward 5 seconds", size: 15), target: nil, action: nil)
        reveal = NSButton(image: .symbol("checkmark.circle.fill", "Reveal export"), target: nil, action: nil)
        super.init(frame: .zero)
        stage.playerView.player = model.player
        for (button, action, help) in [
            (back, #selector(skipBackward), "Back 5 seconds (←)"),
            (play, #selector(togglePlayback), "Play / Pause (Space)"),
            (forward, #selector(skipForward), "Forward 5 seconds (→)"),
            (reveal, #selector(revealExport), "Reveal export"),
        ] {
            button.target = self
            button.action = action
            button.isBordered = false
            button.toolTip = help
        }
        reveal.contentTintColor = .systemGreen
        let playBackground = ColorView(.quaternaryLabelColor, cornerRadius: 8)
        playBackground.addFilling(play)
        let buttons = NSStackView(views: [back, playBackground, forward])
        buttons.spacing = 20
        let times = NSStackView(views: [editedTime, sourceTime])
        times.orientation = .vertical
        times.alignment = .leading
        times.spacing = 3
        previewSwitch.controlSize = .mini
        previewSwitch.target = self
        previewSwitch.action = #selector(togglePreview)
        previewSwitch.setAccessibilityLabel("Preview cuts")
        let previewLabel = NSTextField.label(10)
        previewLabel.stringValue = "Preview cuts"
        let options = NSStackView(views: [previewLabel, previewSwitch, reveal])
        options.spacing = 6

        let transport = barBackground()
        for view in [buttons, times, options] {
            view.translatesAutoresizingMaskIntoConstraints = false
            transport.addSubview(view)
        }
        for view in [stage, transport] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: topAnchor),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: transport.topAnchor),
            transport.leadingAnchor.constraint(equalTo: leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: bottomAnchor),
            playBackground.widthAnchor.constraint(equalToConstant: 36),
            playBackground.heightAnchor.constraint(equalToConstant: 30),
            buttons.topAnchor.constraint(equalTo: transport.topAnchor, constant: 16),
            buttons.centerXAnchor.constraint(equalTo: transport.centerXAnchor),
            times.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            times.leadingAnchor.constraint(equalTo: transport.leadingAnchor, constant: 16),
            times.bottomAnchor.constraint(equalTo: transport.bottomAnchor, constant: -16),
            options.centerYAnchor.constraint(equalTo: times.centerYAnchor),
            options.trailingAnchor.constraint(equalTo: transport.trailingAnchor, constant: -16),
            options.leadingAnchor.constraint(greaterThanOrEqualTo: times.trailingAnchor, constant: 12),
        ])
        observers = [
            Observer { [weak self] in self?.updateTime() },
            Observer { [weak self] in self?.updateControls() },
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateTime() {
        let mapper = model.mapper
        let playhead = model.playhead
        editedTime.stringValue = "\(timeLabel(mapper.sourceToCut(playhead))) / \(timeLabel(mapper.editedDuration))"
        sourceTime.stringValue =
            "Source  \(timeLabel(playhead)) / \(timeLabel(model.project?.media.duration ?? 0))"
    }
    private func updateControls() {
        let playing = model.isPlaying
        play.image = .symbol(
            playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play", size: 16, weight: .semibold)
        play.setAccessibilityLabel(playing ? "Pause" : "Play")
        for button in [back, play, forward] { button.isEnabled = !model.busy }
        previewSwitch.state = model.previewCuts ? .on : .off
        reveal.isHidden = model.exportedURL == nil
        if let media = model.project?.media, media.width > 0, media.height > 0 {
            stage.aspect = Double(media.width) / Double(media.height)
        }
    }
    @objc private func skipBackward() { model.skip(-5) }
    @objc private func skipForward() { model.skip(5) }
    @objc private func togglePlayback() { model.togglePlayback() }
    @objc private func togglePreview() { model.previewCuts = previewSwitch.state == .on }
    @objc private func revealExport() {
        if let url = model.exportedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

/// Dark stage that letterboxes the video in a rounded, shadowed frame.
private final class PlayerStage: NSView {
    let playerView = AVPlayerView()
    private let frameView = NSView()
    var aspect = 16.0 / 9 {
        didSet { if aspect != oldValue { needsLayout = true } }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        // Live Text analysis of a paused frame takes first responder from the timeline.
        playerView.allowsVideoFrameAnalysis = false
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = 10
        playerView.layer?.masksToBounds = true
        playerView.layer?.borderWidth = 1
        playerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        frameView.wantsLayer = true
        frameView.shadow = shadow
        frameView.addSubview(playerView)
        addSubview(frameView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor(white: 0.105, alpha: 1).cgColor }
    override func layout() {
        super.layout()
        let width = max(1, min(bounds.width - 36, (bounds.height - 36) * aspect))
        let size = NSSize(width: width, height: max(1, width / aspect))
        frameView.frame = NSRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
            height: size.height)
        playerView.frame = frameView.bounds
    }
}
