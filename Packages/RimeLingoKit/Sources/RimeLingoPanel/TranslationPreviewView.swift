import AppKit

/// Content of the live translation preview: a header (target language, status line,
/// stale marker), the translation (wrapped, at most `maxLines` lines) and a row of
/// self-drawn controls. Everything is drawn by hand so a click never needs the panel to
/// become key: the view only hit-tests its own control rectangles.
final class TranslationPreviewView: NSView {
    enum Control: Sendable, Equatable, CaseIterable { case submit, copy, retry, exit }

    struct ControlItem: Equatable {
        let control: Control
        let title: String
        let isEnabled: Bool
        var rect: NSRect = .zero
    }

    /// Geometry of one state, in the view's flipped coordinates.
    struct Layout: Equatable {
        var size: NSSize = .zero
        var labelRect: NSRect = .zero
        var messageRect: NSRect = .zero
        /// `.zero` when the translation is not stale.
        var markerRect: NSRect = .zero
        /// `.zero` when there is no translation to show.
        var textRect: NSRect = .zero
        var lineCount = 0
        var controls: [ControlItem] = []
    }

    /// Colors derived from the candidate panel's theme, so both panels match in light
    /// and dark appearance.
    struct Palette: Equatable {
        var text: ThemeColor
        var secondary: ThemeColor
        var accentFill: ThemeColor
        var accentText: ThemeColor

        init(theme: PanelTheme) {
            text = theme.candidateTextColor
            secondary = theme.commentTextColor
            // Schemes without a highlight background get an inverted pill instead.
            if theme.hilitedCandidateBackColor.alpha > 0 {
                accentFill = theme.hilitedCandidateBackColor
                accentText = theme.hilitedCandidateTextColor
            } else {
                accentFill = theme.candidateTextColor
                accentText = ThemeColor(red: theme.backColor.red, green: theme.backColor.green, blue: theme.backColor.blue)
            }
        }
    }

    nonisolated static let maxWidth: CGFloat = 420
    nonisolated static let minWidth: CGFloat = 200
    nonisolated static let maxLines = 6
    nonisolated static let staleOpacity: CGFloat = 0.45
    nonisolated static let disabledOpacity: CGFloat = 0.35
    private static let padX: CGFloat = 12
    private static let padY: CGFloat = 10
    private static let rowGap: CGFloat = 8
    private static let itemGap: CGFloat = 6

    var theme: PanelTheme = .fallback {
        didSet {
            guard theme != oldValue else { return }
            fonts = [:]
            invalidate()
        }
    }

    var state: TranslationPreviewState? {
        didSet { if state != oldValue { invalidate() } }
    }

    /// Widest the view may get; the panel lowers it on narrow screens.
    var widthLimit: CGFloat = TranslationPreviewView.maxWidth {
        didSet { if widthLimit != oldValue { invalidate() } }
    }

    /// Called for a click on an enabled control.
    var onControl: ((Control) -> Void)?

    private var cachedLayout: Layout?
    private var fonts: [String: NSFont] = [:]
    private var pressed: Control?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func invalidate() {
        cachedLayout = nil
        needsDisplay = true
    }

    // MARK: - State mapping

    /// Controls shown for `state`, in display order. Exit is always available; retry is
    /// only present when it can be used.
    nonisolated static func controls(for state: TranslationPreviewState) -> [ControlItem] {
        var items = [
            ControlItem(control: .submit, title: "提交译文", isEnabled: state.canSubmit),
            ControlItem(control: .copy, title: "复制", isEnabled: state.canCopy),
        ]
        if state.canRetry { items.append(ControlItem(control: .retry, title: "重试", isEnabled: true)) }
        items.append(ControlItem(control: .exit, title: "退出", isEnabled: true))
        return items
    }

    /// Badge next to the status line while the shown translation no longer matches the
    /// source: a newer one is on its way, or (automatic translation stopped) it is outdated.
    nonisolated static func staleMarker(for state: TranslationPreviewState) -> String? {
        guard state.isStale, !state.text.isEmpty else { return nil }
        return state.status == .updating ? "更新中" : "已过期"
    }

    nonisolated static func textOpacity(for state: TranslationPreviewState) -> CGFloat {
        state.isStale ? staleOpacity : 1
    }

    // MARK: - Fonts & strings

    private func font(_ face: String, _ size: Double, bold: Bool = false) -> NSFont {
        let key = "\(face)\u{0}\(size)\u{0}\(bold)"
        if let cached = fonts[key] { return cached }
        var resolved: NSFont
        if face.hasPrefix("SF Pro Rounded"), let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded) {
            resolved = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        } else {
            resolved = NSFont(name: face, size: size) ?? .systemFont(ofSize: size)
        }
        if bold { resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask) }
        fonts[key] = resolved
        return resolved
    }

    private var smallPoint: Double { min(max(theme.fontPoint * 0.76, 11), 15) }
    private var textFont: NSFont { font(theme.fontFace, theme.fontPoint) }
    private var smallFont: NSFont { font(theme.fontFace, smallPoint) }
    private var labelFont: NSFont { font(theme.fontFace, smallPoint, bold: true) }

    private func nsColor(_ color: ThemeColor, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha * alpha)
    }

    private func line(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil(line(string, font, .black).size().width)
    }

    private var textLineHeight: CGFloat { lineHeight(textFont) + CGFloat(max(0, theme.lineSpacing)) }

    private func body(_ state: TranslationPreviewState) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.minimumLineHeight = textLineHeight
        style.maximumLineHeight = textLineHeight
        let palette = Palette(theme: theme)
        return NSAttributedString(string: state.text, attributes: [
            .font: textFont, .paragraphStyle: style,
            .foregroundColor: nsColor(palette.text, alpha: Self.textOpacity(for: state)),
        ])
    }

    private static let bodyOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]

    // MARK: - Layout

    var fittingContentSize: NSSize { layout.size }

    var layout: Layout {
        if let cachedLayout { return cachedLayout }
        let computed = computeLayout()
        cachedLayout = computed
        return computed
    }

    private func computeLayout() -> Layout {
        guard let state else { return Layout() }
        var result = Layout()
        let limit = max(Self.minWidth, min(Self.maxWidth, widthLimit)) - Self.padX * 2
        let smallHeight = lineHeight(smallFont)
        let pillHeight = smallHeight + 4

        let labelWidth = width(state.targetLabel, labelFont) + 14
        let messageWidth = state.message.isEmpty ? 0 : width(state.message, smallFont)
        let marker = Self.staleMarker(for: state)
        let markerWidth = marker.map { width($0, smallFont) + 12 } ?? 0
        let headerWidth = labelWidth + (messageWidth > 0 ? 8 + messageWidth : 0) + (markerWidth > 0 ? 8 + markerWidth : 0)

        var controls = Self.controls(for: state)
        let controlWidths = controls.map { width($0.title, smallFont) + 20 }
        let controlsWidth = controlWidths.reduce(0, +) + Self.itemGap * CGFloat(controls.count - 1)
        let controlHeight = smallHeight + 8

        var textSize = NSSize.zero
        if !state.text.isEmpty {
            let maxHeight = textLineHeight * CGFloat(Self.maxLines)
            let bounds = body(state).boundingRect(with: NSSize(width: limit, height: maxHeight + 0.5), options: Self.bodyOptions)
            let lines = min(Self.maxLines, max(1, Int((bounds.height / textLineHeight).rounded())))
            textSize = NSSize(width: min(limit, ceil(bounds.width)), height: textLineHeight * CGFloat(lines))
            result.lineCount = lines
        }

        let contentWidth = min(limit, max(Self.minWidth - Self.padX * 2, headerWidth, controlsWidth, textSize.width))
        var y = Self.padY

        // Header: language pill, status line (truncated when short of room), stale badge.
        result.labelRect = NSRect(x: Self.padX, y: y, width: min(labelWidth, contentWidth), height: pillHeight)
        if markerWidth > 0 {
            result.markerRect = NSRect(x: Self.padX + contentWidth - markerWidth, y: y, width: markerWidth, height: pillHeight)
        }
        let messageX = result.labelRect.maxX + 8
        let messageEnd = Self.padX + contentWidth - (markerWidth > 0 ? markerWidth + 8 : 0)
        if messageWidth > 0, messageEnd > messageX {
            result.messageRect = NSRect(x: messageX, y: y + (pillHeight - smallHeight) / 2,
                                        width: min(messageWidth, messageEnd - messageX), height: smallHeight)
        }
        y += pillHeight + Self.rowGap

        if textSize != .zero {
            result.textRect = NSRect(x: Self.padX, y: y, width: contentWidth, height: textSize.height)
            y += textSize.height + Self.rowGap
        }

        // Controls from the left; exit sits at the right edge, away from submit.
        var x = Self.padX
        for index in controls.indices {
            let isLast = index == controls.count - 1
            let originX = isLast ? max(x, Self.padX + contentWidth - controlWidths[index]) : x
            controls[index].rect = NSRect(x: originX, y: y, width: controlWidths[index], height: controlHeight)
            x += controlWidths[index] + Self.itemGap
        }
        result.controls = controls
        y += controlHeight + Self.padY

        result.size = NSSize(width: ceil(contentWidth + Self.padX * 2), height: ceil(y))
        return result
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        let layout = layout
        let palette = Palette(theme: theme)

        func pill(_ rect: NSRect, _ color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        }
        func centered(_ string: NSAttributedString, in rect: NSRect) {
            let size = string.size()
            string.draw(with: NSRect(x: rect.midX - min(size.width, rect.width) / 2, y: rect.midY - size.height / 2,
                                     width: min(ceil(size.width), rect.width), height: size.height),
                        options: Self.bodyOptions)
        }

        pill(layout.labelRect, nsColor(palette.accentFill))
        centered(line(state.targetLabel, labelFont, nsColor(palette.accentText)), in: layout.labelRect)

        if layout.messageRect != .zero {
            // A failure reason is the main content of the panel: full-strength text.
            let color = state.status == .failed ? nsColor(palette.text) : nsColor(palette.secondary)
            line(state.message, smallFont, color).draw(with: layout.messageRect, options: Self.bodyOptions)
        }
        if layout.markerRect != .zero, let marker = Self.staleMarker(for: state) {
            pill(layout.markerRect, nsColor(palette.text, alpha: 0.1))
            centered(line(marker, smallFont, nsColor(palette.secondary)), in: layout.markerRect)
        }
        if layout.textRect != .zero {
            body(state).draw(with: layout.textRect, options: Self.bodyOptions)
        }

        for item in layout.controls {
            let alpha = item.isEnabled ? 1 : Self.disabledOpacity
            let isPressed = pressed == item.control && item.isEnabled
            let path = NSBezierPath(roundedRect: item.rect, xRadius: 6, yRadius: 6)
            let titleColor: NSColor
            if item.control == .submit {
                nsColor(palette.accentFill, alpha: alpha * (isPressed ? 0.8 : 1)).setFill()
                titleColor = nsColor(palette.accentText, alpha: item.isEnabled ? 1 : 0.7)
            } else {
                nsColor(palette.text, alpha: isPressed ? 0.2 : 0.09).setFill()
                titleColor = nsColor(palette.text, alpha: alpha)
            }
            path.fill()
            centered(line(item.title, smallFont, titleColor), in: item.rect)
        }
    }

    // MARK: - Mouse

    /// The control under `point` (view coordinates), enabled or not.
    func control(at point: NSPoint) -> ControlItem? {
        layout.controls.first { $0.rect.contains(point) }
    }

    /// Reports a click at `point`. Disabled controls and empty areas do nothing.
    @discardableResult
    func click(at point: NSPoint) -> Control? {
        guard let item = control(at: point), item.isEnabled else { return nil }
        onControl?(item.control)
        return item.control
    }

    override func mouseDown(with event: NSEvent) {
        let item = control(at: convert(event.locationInWindow, from: nil))
        pressed = item?.isEnabled == true ? item?.control : nil
        if pressed != nil { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let armed = pressed
        pressed = nil
        needsDisplay = true
        // Fire only when the button is released over the control it went down on.
        guard let armed, control(at: point)?.control == armed else { return }
        click(at: point)
    }
}
