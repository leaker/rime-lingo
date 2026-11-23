import AppKit
@testable import RimeLingoCore
@testable import RimeLingoPanel
import Testing

/// Renders the translation preview offscreen with the real view, RimeLingo's shipped light
/// and dark schemes and the key hints the input method shows, for the README and the
/// website: live translation into English and Japanese, the hint shown when live
/// translation is turned on, and a selected-text translation.
///
///     RIMELINGO_PREVIEW_OUT=<dir> swift test --filter TranslationPreviewShotProbe
@MainActor
@Suite struct TranslationPreviewShotProbe {
    /// Draws the panel's rounded background and edge the way `TranslationPreviewPanel`
    /// styles its container, then the preview on top.
    final class Frame: NSView {
        let preview = TranslationPreviewView()

        init(theme: PanelTheme, state: TranslationPreviewState) {
            preview.theme = theme
            preview.state = state
            let size = preview.fittingContentSize
            super.init(frame: NSRect(origin: .zero, size: size))
            preview.frame = bounds
            addSubview(preview)
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let theme = preview.theme
            let radius = min(theme.cornerRadius, bounds.height / 2)
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            let back = theme.effectiveBackColor
            NSColor(srgbRed: back.red, green: back.green, blue: back.blue, alpha: back.alpha).setFill()
            path.fill()
            let border = theme.borderColor
            if border.alpha > 0 {
                NSColor(srgbRed: border.red, green: border.green, blue: border.blue, alpha: border.alpha).setStroke()
                path.lineWidth = 1
            } else {
                (theme.hasDarkBackground ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).setStroke()
                path.lineWidth = 0.5
            }
            path.stroke()
        }
    }

    @Test func render() throws {
        guard let out = ProcessInfo.processInfo.environment["RIMELINGO_PREVIEW_OUT"] else { return }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let frontend = try ConfigValue.parse(yaml: String(contentsOf: repo.appendingPathComponent("SharedSupport/rimelingo.yaml"), encoding: .utf8))
        // Default key bindings: the hints read exactly as a fresh install shows them.
        let bindings = TranslationShortcutBindings(features: RimeLingoFeatures())
        func ready(_ label: String, _ text: String) -> LiveTranslationSnapshot {
            LiveTranslationSnapshot(targetLabel: label, status: .ready, text: text, isStale: false, message: "",
                                    canSubmit: true, canRetry: false, showsPanel: true)
        }
        let english = ready("英语", "I'll send the meeting notes tonight. Let's go over the launch plan tomorrow morning.")
        let japanese = ready("日语", "今夜、会議メモを送ります。明日の朝、リリース計画を一緒に確認しましょう。")
        let started = bindings.liveStartedHint(for: TranslationTarget(code: "en")!)
        let selection = ready("英语", "Thanks for the quick reply. The new version is ready, please take a look when you have time.")

        let shots: [(String, TranslationPreviewState)] = [
            ("translation-live-en", TranslationPreviewState(
                targetLabel: english.targetLabel, status: .ready, text: english.text,
                message: bindings.liveMessage(english), trailing: bindings.liveTrailingHint(english))),
            ("translation-live-ja", TranslationPreviewState(
                targetLabel: japanese.targetLabel, status: .ready, text: japanese.text,
                message: bindings.liveMessage(japanese), trailing: bindings.liveTrailingHint(japanese))),
            ("translation-started", TranslationPreviewState(
                targetLabel: started.targetLabel, status: .notice, message: started.title, footnote: started.keys)),
            ("translation-selection", TranslationPreviewState(
                targetLabel: selection.targetLabel, status: .ready, text: selection.text,
                footnote: bindings.selectionFootnote(canReplace: true, canRetry: false), kind: .selection))
        ]

        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            var config = frontend
            config.set(false, at: "style/translucency")
            let theme = PanelTheme(frontend: config, dark: dark)
            for (name, state) in shots {
                let view = Frame(theme: theme, state: state)
                try write(view, to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func write(_ view: NSView, to url: URL) throws {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.displayIgnoringOpacity(view.bounds, in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
