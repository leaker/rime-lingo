import AppKit
import Foundation
import Testing
@testable import RimeLingoCore
@testable import RimeLingoPanel

struct TranslationPreviewPanelTests {
    typealias Panel = TranslationPreviewPanel
    typealias View = TranslationPreviewView

    static let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    static let size = NSSize(width: 300, height: 90)

    static func ready(_ text: String = "Hello there") -> TranslationPreviewState {
        TranslationPreviewState(targetLabel: "英语", status: .ready, text: text)
    }

    // MARK: - Positioning

    @Test func anchorSkipsRectsTheClientDidNotPlace() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let pointer = NSPoint(x: 700, y: 300)
        let placed = NSRect(x: 2000, y: 400, width: 80, height: 18)
        let unplaced = [
            NSRect.zero,
            NSRect(x: 0, y: 0, width: 120, height: 18),          // at the screen origin
            NSRect(x: -5000, y: -5000, width: 10, height: 10),   // off every screen
            NSRect(x: CGFloat.infinity, y: 10, width: 1, height: 1),
        ]
        let found = Panel.anchor(candidates: unplaced + [placed], pointer: pointer, screens: screens)
        #expect(found.rect == placed)
        #expect(found.index == unplaced.count)
    }

    @Test func anchorFallsBackToThePointerNotAScreenCorner() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let pointer = NSPoint(x: 700, y: 300)
        let found = Panel.anchor(candidates: [.zero, NSRect(x: 0, y: 0, width: 1, height: 18)], pointer: pointer, screens: screens)
        #expect(found.rect == NSRect(origin: pointer, size: .zero))
        #expect(found.index == nil)
        // A panel anchored there sits just above the pointer, inside the screen.
        let frame = Panel.frame(for: Self.size, caret: found.rect, avoiding: nil, visible: Self.visible)
        #expect(frame.minX == pointer.x && frame.minY > pointer.y)
    }

    @Test func anchorPrefersTheFirstPlacedCandidate() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let first = NSRect(x: 100, y: 200, width: 50, height: 18), second = NSRect(x: 300, y: 400, width: 50, height: 18)
        #expect(Panel.anchor(candidates: [first, second], pointer: .zero, screens: screens).index == 0)
    }

    @Test func sitsAboveTheCaretByDefault() {
        let caret = NSRect(x: 400, y: 500, width: 1, height: 20)
        let frame = Panel.frame(for: Self.size, caret: caret, avoiding: nil, visible: Self.visible)
        #expect(frame == NSRect(x: 400, y: 526, width: 300, height: 90))
    }

    @Test func goesBelowTheCaretWhenThereIsNoRoomAbove() {
        let caret = NSRect(x: 400, y: 860, width: 1, height: 20)
        let frame = Panel.frame(for: Self.size, caret: caret, avoiding: nil, visible: Self.visible)
        #expect(frame.maxY == caret.minY - Panel.gap)
        #expect(frame.minX == 400)
    }

    @Test func clampsHorizontallyIntoTheVisibleFrame() {
        let right = Panel.frame(for: Self.size, caret: NSRect(x: 1400, y: 500, width: 1, height: 20),
                                avoiding: nil, visible: Self.visible)
        #expect(right.maxX == Self.visible.maxX)
        let secondScreen = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let left = Panel.frame(for: Self.size, caret: NSRect(x: 1430, y: 500, width: 1, height: 20),
                               avoiding: nil, visible: secondScreen)
        #expect(left.minX == secondScreen.minX)
    }

    @Test func staysAboveWhenTheCandidatePanelIsBelowTheCaret() {
        let caret = NSRect(x: 400, y: 500, width: 1, height: 20)
        let candidates = NSRect(x: 388, y: 440, width: 420, height: 56)
        let frame = Panel.frame(for: Self.size, caret: caret, avoiding: candidates, visible: Self.visible)
        #expect(frame.minY == caret.maxY + Panel.gap)
        #expect(!frame.intersects(candidates))
    }

    @Test func stacksOnTopOfACandidatePanelThatFlippedAboveTheCaret() {
        let caret = NSRect(x: 400, y: 20, width: 1, height: 20)
        let candidates = NSRect(x: 388, y: 44, width: 420, height: 56)
        let frame = Panel.frame(for: Self.size, caret: caret, avoiding: candidates, visible: Self.visible)
        #expect(frame.minY == candidates.maxY + Panel.gap)
        #expect(!frame.intersects(candidates))
    }

    @Test func goesBelowTheCaretWhenItCannotStackOnTheCandidatePanel() {
        // Short screen: the candidate panel is above the caret and nothing fits on top of it.
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 300)
        let caret = NSRect(x: 400, y: 150, width: 1, height: 20)
        let candidates = NSRect(x: 388, y: 174, width: 420, height: 56)
        let frame = Panel.frame(for: Self.size, caret: caret, avoiding: candidates, visible: visible)
        #expect(frame.maxY == caret.minY - Panel.gap)
        #expect(!frame.intersects(candidates))
    }

    @Test func goesUnderTheCandidatePanelWhenTheCaretIsAtTheTop() {
        let caret = NSRect(x: 400, y: 870, width: 1, height: 20)
        let candidates = NSRect(x: 388, y: 810, width: 420, height: 56)
        let frame = Panel.frame(for: Self.size, caret: caret, avoiding: candidates, visible: Self.visible)
        #expect(frame.maxY == candidates.minY - Panel.gap)
        #expect(frame.maxY <= caret.minY)
    }

    @Test func ignoresACandidatePanelThatIsNotInTheWay() {
        let caret = NSRect(x: 400, y: 500, width: 1, height: 20)
        let plain = Panel.frame(for: Self.size, caret: caret, avoiding: nil, visible: Self.visible)
        let aside = Panel.frame(for: Self.size, caret: caret, avoiding: NSRect(x: 900, y: 520, width: 300, height: 60),
                                visible: Self.visible)
        let empty = Panel.frame(for: Self.size, caret: caret, avoiding: .zero, visible: Self.visible)
        #expect(aside == plain)
        #expect(empty == plain)
    }

    @Test func staysOnScreenWhenNothingFits() {
        let visible = NSRect(x: 0, y: 0, width: 200, height: 100)
        let caret = NSRect(x: 50, y: 40, width: 1, height: 20)
        let frame = Panel.frame(for: Self.size, caret: caret, avoiding: nil, visible: visible)
        #expect(frame.minX == visible.minX)
        #expect(frame.minY >= visible.minY)
        #expect(frame.size == Self.size)
    }

    // MARK: - State to view

    static let hint = "⌥↩ 替换选区   esc 关闭"

    @MainActor
    @Test func theTrailingHintUsesOnlySpareHeaderRoom() {
        let view = View()
        // A short translation leaves the header at the minimum width: the hint fits at its right end.
        view.state = TranslationPreviewState(targetLabel: "日语", status: .ready, text: "ああ", trailing: "⌥↩ 上屏译文")
        let plain = TranslationPreviewState(targetLabel: "日语", status: .ready, text: "ああ")
        let layout = view.layout
        #expect(!layout.trailingRect.isEmpty)
        #expect(layout.trailingRect.minX >= layout.labelRect.maxX + 8)
        #expect(layout.trailingRect.maxX <= layout.size.width)
        view.state = plain
        #expect(view.layout.size == layout.size, "the hint never changes the panel's size")
        // A status line that needs the room keeps it: the hint is left out, the size unchanged.
        let long = "请求失败，网络连接已断开，请稍后再试一次"
        view.state = TranslationPreviewState(targetLabel: "日语", status: .failed, message: long, trailing: "⌥↩ 上屏译文 以及更多更多更多说明文字文字文字文字")
        let crowded = view.layout
        view.state = TranslationPreviewState(targetLabel: "日语", status: .failed, message: long)
        #expect(crowded.trailingRect == .zero)
        #expect(crowded.size == view.layout.size)
    }

    @MainActor
    @Test func selectionPreviewShowsItsKeyHintsAsAFootnote() {
        let view = View()
        view.state = TranslationPreviewState(targetLabel: "英语", status: .ready, text: "Hello", footnote: Self.hint, kind: .selection)
        let layout = view.layout
        #expect(!layout.footnoteRect.isEmpty)
        #expect(layout.footnoteRect.minY >= layout.textRect.maxY)
        // A failure has no translation; the hint is still there, under the header.
        view.state = TranslationPreviewState(targetLabel: "日语", status: .failed, message: "请求失败",
                                             footnote: "⌥↩ 重试   esc 关闭", kind: .selection)
        #expect(view.layout.textRect == .zero)
        #expect(!view.layout.footnoteRect.isEmpty)
        #expect(view.layout.footnoteRect.minY >= view.layout.labelRect.maxY)
    }

    @MainActor
    @Test func noFootnoteTakesNoRoom() {
        let view = View()
        view.state = Self.ready()
        let plain = view.layout
        #expect(plain.footnoteRect == .zero)
        // Nothing but the bottom padding under the translation.
        #expect(plain.size.height - plain.textRect.maxY == plain.labelRect.minY)

        var state = Self.ready()
        state.footnote = Self.hint
        view.state = state
        let hinted = view.layout
        #expect(hinted.size.height > plain.size.height)
        #expect(hinted.textRect == plain.textRect)
    }

    @MainActor
    @Test func hintWithoutATranslationIsShorterThanAPreview() {
        let view = View()
        view.state = TranslationPreviewState(targetLabel: "英语", status: .ready, text: "Hello", footnote: Self.hint)
        let full = view.layout
        view.state = TranslationPreviewState(targetLabel: "英语", status: .notice, text: "", message: "实时翻译已开启", footnote: Self.hint)
        let hint = view.layout
        #expect(hint.textRect == .zero && hint.lineCount == 0)
        #expect(hint.messageRect != .zero && !hint.footnoteRect.isEmpty)
        #expect(hint.size.height < full.size.height)
        #expect(hint.footnoteRect.minY >= hint.labelRect.maxY)
    }

    @MainActor
    @Test func messageStartsAtTheLeftMarginWithoutATargetLabel() {
        let view = View()
        view.state = TranslationPreviewState(targetLabel: "英语", status: .notice, message: "已切换翻译语言")
        let labelled = view.layout
        view.state = TranslationPreviewState(targetLabel: "", status: .notice, message: "翻译已关闭", footnote: Self.hint)
        let bare = view.layout
        #expect(bare.labelRect == .zero)
        #expect(bare.messageRect.minX == labelled.labelRect.minX)
        #expect(bare.messageRect.minX == bare.footnoteRect.minX)
        #expect(labelled.messageRect.minX > labelled.labelRect.maxX)
    }

    @MainActor
    @Test func longFootnotesAreTruncatedNotWidened() {
        let view = View()
        var state = Self.ready()
        state.footnote = String(repeating: Self.hint + "   ", count: 12)
        view.state = state
        #expect(view.layout.size.width == View.maxWidth)
        #expect(view.layout.footnoteRect.maxX <= view.layout.size.width)
        view.widthLimit = 260
        #expect(view.layout.size.width <= 260)
        #expect(view.layout.footnoteRect.maxX <= view.layout.size.width)
        // A short one widens the panel only as far as it needs.
        state.footnote = Self.hint
        view.widthLimit = View.maxWidth
        view.state = state
        #expect(view.layout.size.width < View.maxWidth)
    }

    @Test func staleTranslationsAreDimmedAndMarked() {
        var state = Self.ready()
        #expect(View.staleMarker(for: state) == nil)
        #expect(View.textOpacity(for: state) == 1)

        state.status = .updating
        state.isStale = true
        #expect(View.staleMarker(for: state) == "更新中")
        #expect(View.textOpacity(for: state) == View.staleOpacity)

        // Automatic translation stopped: nothing is on its way.
        state.status = .notice
        #expect(View.staleMarker(for: state) == "已过期")

        state.text = ""
        #expect(View.staleMarker(for: state) == nil)
    }

    @MainActor
    @Test func laysOutHeaderTextAndFootnoteWithoutOverlap() {
        let view = View()
        view.theme = PanelTheme(frontend: PanelTests.frontend, dark: false)
        view.state = TranslationPreviewState(targetLabel: "英语", status: .updating, text: "See you tomorrow", isStale: true,
                                             message: "翻译中…", footnote: Self.hint)
        let layout = view.layout
        let bounds = NSRect(origin: .zero, size: layout.size)
        #expect(layout.size.width >= View.minWidth && layout.size.width <= View.maxWidth)
        #expect(layout.lineCount == 1)
        #expect(layout.markerRect != .zero)
        let rects = [layout.labelRect, layout.messageRect, layout.markerRect, layout.textRect, layout.footnoteRect]
        #expect(rects.allSatisfy { !$0.isEmpty })
        for (index, rect) in rects.enumerated() {
            #expect(bounds.contains(rect))
            for other in rects[(index + 1)...] { #expect(!rect.intersects(other)) }
        }
        // Header, then the translation, then the footnote.
        #expect(layout.labelRect.maxY <= layout.textRect.minY)
        #expect(layout.footnoteRect.minY >= layout.textRect.maxY)
    }

    @MainActor
    @Test func waitingStateHasNoTextArea() {
        let view = View()
        // A session without a source has no message of its own.
        view.state = TranslationPreviewState(targetLabel: "英语", status: .waiting)
        #expect(view.layout.textRect == .zero)
        #expect(view.layout.lineCount == 0)
        #expect(view.layout.markerRect == .zero)
        view.state = nil
        #expect(view.fittingContentSize == .zero)
    }

    @MainActor
    @Test func longTranslationsWrapAndStopAtSixLines() {
        let view = View()
        view.state = Self.ready(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4))
        let wrapped = view.layout
        #expect(wrapped.lineCount > 1 && wrapped.lineCount <= View.maxLines)
        #expect(wrapped.size.width <= View.maxWidth)

        view.state = Self.ready(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 80))
        let truncated = view.layout
        #expect(truncated.lineCount == View.maxLines)
        #expect(truncated.size.width == View.maxWidth)
        #expect(truncated.textRect.height == wrapped.textRect.height / CGFloat(wrapped.lineCount) * CGFloat(View.maxLines))
    }

    @MainActor
    @Test func narrowScreensLowerTheWidthLimit() {
        let view = View()
        view.widthLimit = 260
        view.state = Self.ready(String(repeating: "word ", count: 60))
        #expect(view.layout.size.width <= 260)
        #expect(view.layout.textRect.maxX <= view.layout.size.width)
    }

    @MainActor
    @Test func previewTakesNoClicks() {
        let view = View()
        view.state = Self.ready()
        #expect(!view.acceptsFirstMouse(for: nil))
        #expect(!view.acceptsFirstResponder)
        // The window lets clicks through to the application underneath.
        #expect(Panel().ignoresMouse)
    }

    @Test func paletteFollowsTheTheme() {
        let light = View.Palette(theme: PanelTheme(frontend: PanelTests.frontend, dark: false))
        let dark = View.Palette(theme: PanelTheme(frontend: PanelTests.frontend, dark: true))
        #expect(light.text != dark.text)
        for (palette, theme) in [(light, PanelTheme(frontend: PanelTests.frontend, dark: false)),
                                 (dark, PanelTheme(frontend: PanelTests.frontend, dark: true))] {
            #expect(palette.text == theme.candidateTextColor)
            #expect(palette.accentText.contrast(with: palette.accentFill) >= 3)
        }
        var flat = PanelTheme.fallback
        flat.hilitedCandidateBackColor = .clear
        let inverted = View.Palette(theme: flat)
        #expect(inverted.accentFill == flat.candidateTextColor)
        #expect(inverted.accentFill.alpha > 0)
    }

    // MARK: - Panel

    @MainActor
    @Test func panelShowsUpdatesAndHidesWithoutTakingFocus() {
        let panel = Panel()
        #expect(!panel.canTakeFocus)
        #expect(!panel.isVisible)
        #expect(panel.frame == .zero)
        #expect(panel.state == nil)

        // Hidden: updates and repositioning do nothing.
        panel.update(Self.ready())
        panel.reposition(caret: NSRect(x: 300, y: 300, width: 1, height: 20), avoiding: nil)
        #expect(!panel.isVisible && panel.state == nil)

        let caret = NSRect(x: 300, y: 300, width: 1, height: 20)
        panel.show(Self.ready(), caret: caret, avoiding: nil)
        defer { panel.hide() }
        #expect(panel.isVisible)
        #expect(panel.state == Self.ready())
        #expect(panel.frame.size == panel.contentView.fittingContentSize)
        let shown = panel.frame

        // New content keeps the panel on its side of the caret.
        panel.update(Self.ready(String(repeating: "A longer translation of the same sentence. ", count: 6)))
        #expect(panel.frame.height > shown.height)
        #expect(panel.frame.minY == shown.minY)

        // `.zero` reuses the last caret; an obstacle moves the panel off it.
        let obstacle = panel.frame
        panel.reposition(caret: .zero, avoiding: obstacle)
        #expect(!panel.frame.intersects(obstacle))

        panel.hide()
        #expect(!panel.isVisible)
        #expect(panel.frame == .zero)
        #expect(panel.state == nil)
    }

    @MainActor
    @Test func panelFollowsTheThemeAndSizesToItsFootnote() {
        let panel = Panel()
        panel.theme = PanelTheme(frontend: PanelTests.frontend, dark: true)
        #expect(panel.contentView.theme.schemeName == "rimelingo_dark")
        let caret = NSRect(x: 300, y: 300, width: 1, height: 20)
        panel.show(TranslationPreviewState(targetLabel: "日语", status: .notice, text: "こんにちは", isStale: true, message: "超过 200 字"),
                   caret: caret, avoiding: nil)
        defer { panel.hide() }
        let plain = panel.frame
        panel.update(TranslationPreviewState(targetLabel: "日语", status: .notice, text: "こんにちは", isStale: true,
                                             message: "超过 200 字", footnote: Self.hint))
        #expect(panel.frame.height > plain.height)
        #expect(panel.frame.size == panel.contentView.fittingContentSize)
    }

    @MainActor
    @Test func candidatePanelReportsItsOccupiedFrame() {
        let panel = CandidatePanel()
        panel.animationsEnabled = false
        #expect(panel.occupiedFrame == nil)
        panel.show(PanelState(candidates: [.init(label: "1", text: "你好")]), at: NSRect(x: 300, y: 300, width: 1, height: 20))
        let occupied = panel.occupiedFrame
        #expect(occupied?.size == panel.frameSize)
        #expect(occupied.map { $0.maxY <= 300 || $0.minY >= 320 } == true)
        panel.hide()
        #expect(panel.occupiedFrame == nil)
    }
}
