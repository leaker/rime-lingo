public import AppKit

/// What the translation preview shows, for live translation input or for a selected-text
/// translation. A plain value: the host maps its session snapshot onto it field by field.
public struct TranslationPreviewState: Sendable, Equatable {
    /// `notice` is an informational stop (for example the source is over the automatic limit).
    public enum Status: Sendable, Equatable { case waiting, updating, ready, failed, notice }
    /// Which workflow the preview belongs to. Only the control titles differ: a selection
    /// preview offers 替换选区 / 取消 where live input offers 提交译文 / 退出.
    public enum Kind: Sendable, Equatable { case live, selection }

    public var kind: Kind
    public var targetLabel: String
    public var status: Status
    public var text: String
    /// The translation no longer matches the source: drawn dimmed, with a marker.
    public var isStale: Bool
    /// Status line; the reason when `status` is `failed`.
    public var message: String
    public var canSubmit: Bool
    public var canCopy: Bool
    /// Shows the retry control. Exit is always available.
    public var canRetry: Bool

    public init(targetLabel: String, status: Status, text: String = "", isStale: Bool = false, message: String = "",
                canSubmit: Bool = false, canCopy: Bool = false, canRetry: Bool = false, kind: Kind = .live) {
        self.kind = kind
        self.targetLabel = targetLabel
        self.status = status
        self.text = text
        self.isStale = isStale
        self.message = message
        self.canSubmit = canSubmit
        self.canCopy = canCopy
        self.canRetry = canRetry
    }
}

/// The preview never takes keyboard focus: typing keeps going to the client application.
private final class PreviewWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Borderless, non-activating window that floats the live translation next to the text
/// cursor, above it by default, and keeps clear of the candidate panel.
@MainActor
public final class TranslationPreviewPanel {
    private let window: NSPanel
    private let view = TranslationPreviewView()
    private let container = NSView()
    private let effect = NSVisualEffectView()
    private var lastCaret: NSRect = .zero
    private var lastAvoiding: NSRect?
    /// Fetched when the panel appears: asking AppKit on every update round-trips to the
    /// window server.
    private var screenFrames: [(frame: NSRect, visible: NSRect)] = []

    /// Distance kept from the caret and from the candidate panel.
    nonisolated static let gap: CGFloat = 6

    public var theme: PanelTheme {
        get { view.theme }
        set {
            guard newValue != view.theme else { return }
            view.theme = newValue
            styleContainer()
            if window.isVisible { place() }
        }
    }

    public var onSubmit: (@MainActor () -> Void)?
    public var onCopy: (@MainActor () -> Void)?
    public var onExit: (@MainActor () -> Void)?
    public var onRetry: (@MainActor () -> Void)?

    public var isVisible: Bool { window.isVisible }
    public private(set) var state: TranslationPreviewState?
    /// Screen coordinates; `.zero` while hidden.
    public var frame: NSRect { window.isVisible ? window.frame : .zero }

    public init() {
        window = PreviewWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.animationBehavior = .none

        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isHidden = true
        for subview in [effect, view] as [NSView] {
            subview.autoresizingMask = [.width, .height]
            container.addSubview(subview)
        }
        window.contentView = container
        view.onControl = { [weak self] control in self?.dispatch(control) }
        styleContainer()
    }

    /// Shows or updates the preview. `caret` is the cursor rectangle in screen coordinates
    /// (`.zero` reuses the last one); `avoiding` is the space the candidate panel takes.
    public func show(_ state: TranslationPreviewState, caret: NSRect, avoiding: NSRect?) {
        let appearing = !window.isVisible
        if appearing || screenFrames.isEmpty { screenFrames = NSScreen.screens.map { ($0.frame, $0.visibleFrame) } }
        if caret != .zero { lastCaret = caret }
        lastAvoiding = avoiding
        self.state = state
        view.state = state
        place()
        if appearing { window.orderFrontRegardless() }
    }

    /// Replaces the content where the panel is. Does nothing while hidden.
    public func update(_ state: TranslationPreviewState) {
        guard window.isVisible else { return }
        self.state = state
        view.state = state
        place()
    }

    /// Follows the caret and the candidate panel. Does nothing while hidden.
    public func reposition(caret: NSRect, avoiding: NSRect?) {
        guard window.isVisible else { return }
        if caret != .zero { lastCaret = caret }
        lastAvoiding = avoiding
        place()
    }

    public func hide() {
        state = nil
        view.state = nil
        if window.isVisible { window.orderOut(nil) }
    }

    /// Where a preview of `size` goes: above `caret` by default, below when there is no
    /// room. When that would cover `avoiding` it moves to the far side of it (stacked on
    /// top of a candidate panel that flipped above the caret, under one that sits below).
    /// Always clamped horizontally into `visible`.
    public nonisolated static func frame(for size: NSSize, caret: NSRect, avoiding: NSRect?, visible: NSRect) -> NSRect {
        let x = min(max(caret.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
        func rect(_ y: CGFloat) -> NSRect { NSRect(x: x, y: y, width: size.width, height: size.height) }
        let obstacle = avoiding.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }

        func isUsable(_ candidate: NSRect) -> Bool {
            guard candidate.minY >= visible.minY, candidate.maxY <= visible.maxY else { return false }
            // The caret may have no width, so only its line is compared.
            guard candidate.minY >= caret.maxY || candidate.maxY <= caret.minY else { return false }
            guard let obstacle else { return true }
            return candidate.maxX <= obstacle.minX || candidate.minX >= obstacle.maxX
                || candidate.maxY <= obstacle.minY || candidate.minY >= obstacle.maxY
        }

        let above = rect(caret.maxY + gap)
        var candidates = [above]
        if let obstacle { candidates.append(rect(obstacle.maxY + gap)) }
        candidates.append(rect(caret.minY - gap - size.height))
        if let obstacle { candidates.append(rect(obstacle.minY - gap - size.height)) }
        if let usable = candidates.first(where: isUsable) { return usable }
        // Nothing fits (a tiny screen): stay as close to the default place as the screen allows.
        return rect(min(max(above.minY, visible.minY), max(visible.minY, visible.maxY - size.height)))
    }

    /// The first of `candidates` that a client really placed on a screen, with its index;
    /// otherwise an empty rect at `pointer` with a nil index. Clients that cannot place a
    /// range answer with an empty rect, a rect at the screen origin, or one off every
    /// screen, and a panel anchored there lands in a corner far from the text. The pointer
    /// is the best remaining guess: the selection was usually just made with it.
    public nonisolated static func anchor(candidates: [NSRect], pointer: NSPoint, screens: [NSRect]) -> (rect: NSRect, index: Int?) {
        func isPlaced(_ rect: NSRect) -> Bool {
            guard rect != .zero, rect.origin != .zero else { return false }
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return false }
            return screens.contains { $0.contains(rect.origin) || $0.intersects(rect) }
        }
        if let index = candidates.firstIndex(where: isPlaced) { return (candidates[index], index) }
        return (NSRect(origin: pointer, size: .zero), nil)
    }

    // MARK: - Internals

    /// The content view, for tests.
    var contentView: TranslationPreviewView { view }
    /// Whether the window could ever take keyboard focus (for tests).
    var canTakeFocus: Bool { window.canBecomeKey || window.canBecomeMain }

    private func dispatch(_ control: TranslationPreviewView.Control) {
        switch control {
        case .submit: onSubmit?()
        case .copy: onCopy?()
        case .retry: onRetry?()
        case .exit: onExit?()
        }
    }

    private var visibleFrame: NSRect {
        let screens = screenFrames.isEmpty ? NSScreen.screens.map { ($0.frame, $0.visibleFrame) } : screenFrames
        return (screens.first { $0.0.contains(lastCaret.origin) } ?? screens.first)?.1
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func place() {
        let visible = visibleFrame
        view.widthLimit = min(TranslationPreviewView.maxWidth, visible.width)
        let size = view.fittingContentSize
        let frame = Self.frame(for: size, caret: lastCaret, avoiding: lastAvoiding, visible: visible)
        if window.frame.size != frame.size {
            window.setFrame(frame, display: false)
            styleContainer()
            window.invalidateShadow()
        } else if window.frame.origin != frame.origin {
            window.setFrameOrigin(frame.origin)
        }
        view.needsDisplay = true
    }

    private func styleContainer() {
        guard let layer = container.layer else { return }
        let theme = view.theme
        let back = theme.effectiveBackColor
        layer.backgroundColor = CGColor(srgbRed: back.red, green: back.green, blue: back.blue, alpha: back.alpha)
        layer.cornerRadius = min(theme.cornerRadius, max(0, container.bounds.height / 2))
        let border = theme.borderColor
        if border.alpha > 0 {
            layer.borderWidth = 1
            layer.borderColor = CGColor(srgbRed: border.red, green: border.green, blue: border.blue, alpha: border.alpha)
        } else {
            // A hairline keeps the edge crisp on backgrounds of similar brightness.
            layer.borderWidth = 1 / max(1, window.backingScaleFactor)
            layer.borderColor = theme.hasDarkBackground ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.1)
        }
        let appearance = NSAppearance(named: theme.hasDarkBackground ? .darkAqua : .aqua)
        if effect.appearance?.name != appearance?.name { effect.appearance = appearance }
        effect.isHidden = !theme.translucency
    }
}
