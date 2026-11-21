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
        TranslationPreviewState(targetLabel: "英语", status: .ready, text: text, canSubmit: true, canCopy: true)
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

    @Test func selectionPreviewOffersReplaceCopyAndCancel() {
        var state = TranslationPreviewState(targetLabel: "英语", status: .ready, text: "Hello", canSubmit: true, canCopy: true, kind: .selection)
        #expect(View.controls(for: state).map(\.title) == ["替换选区", "复制", "取消"])
        #expect(View.controls(for: state).map(\.control) == [.submit, .copy, .exit])
        // Replacing became unsafe: the control stays visible but off, copy and cancel stay on.
        state.canSubmit = false
        state.message = "原文已变化，无法替换"
        #expect(View.controls(for: state).map(\.isEnabled) == [false, true, true])
        let failed = TranslationPreviewState(targetLabel: "日语", status: .failed, message: "请求失败", canRetry: true, kind: .selection)
        #expect(View.controls(for: failed).map(\.title) == ["替换选区", "复制", "重试", "取消"])
    }

    @Test func exitIsAlwaysAvailableAndRetryOnlyWhenOffered() {
        let waiting = TranslationPreviewState(targetLabel: "英语", status: .waiting, message: "等待输入")
        let controls = View.controls(for: waiting)
        #expect(controls.map(\.control) == [.submit, .copy, .exit])
        #expect(controls.map(\.title) == ["提交译文", "复制", "退出"])
        #expect(controls.map(\.isEnabled) == [false, false, true])

        let failed = TranslationPreviewState(targetLabel: "日语", status: .failed, message: "请求失败", canRetry: true)
        #expect(View.controls(for: failed).map(\.control) == [.submit, .copy, .retry, .exit])
        #expect(View.controls(for: failed).first { $0.control == .retry }?.title == "重试")

        #expect(View.controls(for: Self.ready()).map(\.isEnabled) == [true, true, true])
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
    @Test func laysOutHeaderTextAndControlsWithoutOverlap() {
        let view = View()
        view.theme = PanelTheme(frontend: PanelTests.frontend, dark: false)
        view.state = TranslationPreviewState(targetLabel: "英语", status: .updating, text: "See you tomorrow", isStale: true,
                                             message: "翻译中…")
        let layout = view.layout
        let bounds = NSRect(origin: .zero, size: layout.size)
        #expect(layout.size.width >= View.minWidth && layout.size.width <= View.maxWidth)
        #expect(layout.lineCount == 1)
        #expect(layout.markerRect != .zero)
        let rects = [layout.labelRect, layout.messageRect, layout.markerRect, layout.textRect] + layout.controls.map(\.rect)
        for (index, rect) in rects.enumerated() {
            #expect(bounds.contains(rect))
            for other in rects[(index + 1)...] { #expect(!rect.intersects(other)) }
        }
        // Header, then the translation, then the controls.
        #expect(layout.labelRect.maxY <= layout.textRect.minY)
        #expect(layout.controls.allSatisfy { $0.rect.minY >= layout.textRect.maxY })
        #expect(layout.controls.last?.control == .exit)
    }

    @MainActor
    @Test func waitingStateHasNoTextArea() {
        let view = View()
        view.state = TranslationPreviewState(targetLabel: "英语", status: .waiting, message: "等待输入")
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
        #expect(view.layout.controls.allSatisfy { $0.rect.maxX <= view.layout.size.width })
    }

    @MainActor
    @Test func clicksReachEnabledControlsOnly() {
        let view = View()
        var clicked: [View.Control] = []
        view.onControl = { clicked.append($0) }
        view.state = TranslationPreviewState(targetLabel: "英语", status: .failed, message: "请求失败", canRetry: true)
        func center(_ control: View.Control) -> NSPoint {
            let rect = view.layout.controls.first { $0.control == control }!.rect
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        #expect(view.click(at: center(.submit)) == nil)
        #expect(view.click(at: center(.copy)) == nil)
        #expect(view.click(at: NSPoint(x: 2, y: 2)) == nil)
        #expect(clicked.isEmpty)
        view.click(at: center(.retry))
        view.click(at: center(.exit))
        #expect(clicked == [.retry, .exit])

        view.state = Self.ready()
        view.click(at: center(.submit))
        view.click(at: center(.copy))
        #expect(clicked == [.retry, .exit, .submit, .copy])
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(!view.acceptsFirstResponder)
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
    @Test func panelControlsCallTheirCallbacks() {
        let panel = Panel()
        var calls: [String] = []
        panel.onSubmit = { calls.append("submit") }
        panel.onCopy = { calls.append("copy") }
        panel.onRetry = { calls.append("retry") }
        panel.onExit = { calls.append("exit") }
        panel.theme = PanelTheme(frontend: PanelTests.frontend, dark: true)
        #expect(panel.contentView.theme.schemeName == "rimelingo_dark")
        panel.show(TranslationPreviewState(targetLabel: "日语", status: .notice, text: "こんにちは", isStale: true,
                                           message: "超过 200 字，按当前语言快捷键刷新", canRetry: true),
                   caret: NSRect(x: 300, y: 300, width: 1, height: 20), avoiding: nil)
        defer { panel.hide() }
        for item in panel.contentView.layout.controls {
            panel.contentView.click(at: NSPoint(x: item.rect.midX, y: item.rect.midY))
        }
        #expect(calls == ["retry", "exit"])
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
