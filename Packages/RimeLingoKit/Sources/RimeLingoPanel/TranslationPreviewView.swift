import AppKit

/// Content of the translation preview: a header (target language, status line, stale
/// marker), the translation (wrapped, at most `maxLines` lines) and an optional footnote
/// of key hints. Text only, drawn by hand: there is nothing to click, the keyboard does
/// everything.
final class TranslationPreviewView: NSView {
    /// Geometry of one state, in the view's flipped coordinates.
    struct Layout: Equatable {
        var size: NSSize = .zero
        /// `.zero` when the state has no target label.
        var labelRect: NSRect = .zero
        var messageRect: NSRect = .zero
        /// `.zero` when the state has no trailing hint or the header has no room for it.
        var trailingRect: NSRect = .zero
        /// `.zero` when the translation is not stale.
        var markerRect: NSRect = .zero
        /// `.zero` when there is no translation to show.
        var textRect: NSRect = .zero
        var lineCount = 0
        /// `.zero` when the state has no footnote.
        var footnoteRect: NSRect = .zero
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
    private static let padX: CGFloat = 12
    private static let padY: CGFloat = 10
    private static let rowGap: CGFloat = 8

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

    private var cachedLayout: Layout?
    private var fonts: [String: NSFont] = [:]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    private func invalidate() {
        cachedLayout = nil
        needsDisplay = true
    }

    // MARK: - State mapping

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

        let labelWidth = state.targetLabel.isEmpty ? 0 : width(state.targetLabel, labelFont) + 14
        let messageWidth = state.message.isEmpty ? 0 : width(state.message, smallFont)
        let marker = Self.staleMarker(for: state)
        let markerWidth = marker.map { width($0, smallFont) + 12 } ?? 0
        // Header items are 8 apart.
        let headerWidths = [labelWidth, messageWidth, markerWidth].filter { $0 > 0 }
        let headerWidth = headerWidths.reduce(0, +) + 8 * CGFloat(max(0, headerWidths.count - 1))
        let footnoteWidth = state.footnote.isEmpty ? 0 : width(state.footnote, smallFont)

        var textSize = NSSize.zero
        if !state.text.isEmpty {
            let maxHeight = textLineHeight * CGFloat(Self.maxLines)
            let bounds = body(state).boundingRect(with: NSSize(width: limit, height: maxHeight + 0.5), options: Self.bodyOptions)
            let lines = min(Self.maxLines, max(1, Int((bounds.height / textLineHeight).rounded())))
            textSize = NSSize(width: min(limit, ceil(bounds.width)), height: textLineHeight * CGFloat(lines))
            result.lineCount = lines
        }

        let contentWidth = min(limit, max(Self.minWidth - Self.padX * 2, headerWidth, footnoteWidth, textSize.width))
        var y = Self.padY

        // Header: language pill, status line (truncated when short of room), stale badge.
        // Without a target label the status line starts at the left margin.
        if labelWidth > 0 {
            result.labelRect = NSRect(x: Self.padX, y: y, width: min(labelWidth, contentWidth), height: pillHeight)
        }
        if markerWidth > 0 {
            result.markerRect = NSRect(x: Self.padX + contentWidth - markerWidth, y: y, width: markerWidth, height: pillHeight)
        }
        let messageX = labelWidth > 0 ? result.labelRect.maxX + 8 : Self.padX
        let messageEnd = Self.padX + contentWidth - (markerWidth > 0 ? markerWidth + 8 : 0)
        if messageWidth > 0, messageEnd > messageX {
            result.messageRect = NSRect(x: messageX, y: y + (pillHeight - smallHeight) / 2,
                                        width: min(messageWidth, messageEnd - messageX), height: smallHeight)
        }
        // The trailing hint only uses room the header has anyway: it never widens the panel
        // and never squeezes the status line.
        if !state.trailing.isEmpty {
            let trailingWidth = width(state.trailing, smallFont)
            let start = result.messageRect == .zero ? messageX : result.messageRect.maxX + 12
            if messageWidth <= messageEnd - messageX, trailingWidth <= messageEnd - start {
                result.trailingRect = NSRect(x: messageEnd - trailingWidth, y: y + (pillHeight - smallHeight) / 2,
                                             width: trailingWidth, height: smallHeight)
            }
        }
        y += pillHeight

        if textSize != .zero {
            y += Self.rowGap
            result.textRect = NSRect(x: Self.padX, y: y, width: contentWidth, height: textSize.height)
            y += textSize.height
        }

        // Key hints: one line, truncated at the tail when wider than the panel may get.
        if footnoteWidth > 0 {
            y += Self.rowGap
            result.footnoteRect = NSRect(x: Self.padX, y: y, width: min(footnoteWidth, contentWidth), height: smallHeight)
            y += smallHeight
        }
        y += Self.padY

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

        if layout.labelRect != .zero {
            pill(layout.labelRect, nsColor(palette.accentFill))
            centered(line(state.targetLabel, labelFont, nsColor(palette.accentText)), in: layout.labelRect)
        }

        if layout.messageRect != .zero {
            // A failure reason is the main content of the panel: full-strength text.
            let color = state.status == .failed ? nsColor(palette.text) : nsColor(palette.secondary)
            line(state.message, smallFont, color).draw(with: layout.messageRect, options: Self.bodyOptions)
        }
        if layout.trailingRect != .zero {
            line(state.trailing, smallFont, nsColor(palette.secondary, alpha: 0.75)).draw(with: layout.trailingRect, options: Self.bodyOptions)
        }
        if layout.markerRect != .zero, let marker = Self.staleMarker(for: state) {
            pill(layout.markerRect, nsColor(palette.text, alpha: 0.1))
            centered(line(marker, smallFont, nsColor(palette.secondary)), in: layout.markerRect)
        }
        if layout.textRect != .zero {
            body(state).draw(with: layout.textRect, options: Self.bodyOptions)
        }
        if layout.footnoteRect != .zero {
            line(state.footnote, smallFont, nsColor(palette.secondary)).draw(with: layout.footnoteRect, options: Self.bodyOptions)
        }
    }
}
