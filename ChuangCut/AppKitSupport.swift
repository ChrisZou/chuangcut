import AppKit
import Observation

/// Runs `apply` now and again after any observable property it read changes. Changes made in the
/// same main-loop turn are coalesced into one call, which runs after the new values are stored.
/// Views keep one observer per concern so the 30 Hz playhead only reruns the cheap ones.
@MainActor final class Observer {
    private let apply: () -> Void
    init(_ apply: @escaping () -> Void) {
        self.apply = apply
        run()
    }
    private func run() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.run() }
        }
    }
}

func timeLabel(_ seconds: Double) -> String {
    String(format: "%02d:%04.1f", Int(max(0, seconds)) / 60, max(0, seconds).truncatingRemainder(dividingBy: 60))
}

extension NSTextField {
    static func label(
        _ size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false, color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font =
            mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

extension NSImage {
    static func symbol(
        _ name: String, _ description: String? = nil, size: CGFloat? = nil, weight: NSFont.Weight = .regular
    ) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        guard let size else { return image }
        return image.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? image
    }
}

extension NSView {
    /// Adds `child` with its edges pinned to this view's edges.
    func addFilling(_ child: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// The translucent bar material SwiftUI calls `.bar`.
func barBackground() -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .titlebar
    view.blendingMode = .withinWindow
    return view
}

func separator(vertical: Bool = false) -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    box.translatesAutoresizingMaskIntoConstraints = false
    if vertical {
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
    } else {
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    return box
}

/// A layer-backed view filled with a dynamic color that follows light and dark mode.
class ColorView: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    init(_ color: NSColor, cornerRadius: CGFloat = 0) {
        self.color = color
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
        layer?.cornerRadius = cornerRadius
    }
}
