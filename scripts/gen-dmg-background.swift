#!/usr/bin/env swift
// Renders the picture behind the icons in the release disk image's Finder window:
//   scripts/dmg/background.tiff   one TIFF holding the 1x and the 2x rendering
//
// The picture says what to do with the image: double-click the app, then click Install.
// It is committed, so a release does not need the fonts; run this again only when the
// wording or the layout changes:
//   swift scripts/gen-dmg-background.swift [output.tiff]
// Text is set in Source Han Sans SC (SIL OFL 1.1), which must be installed. The colours
// are those of scripts/gen-rimelingo-artwork.swift.
//
// Coordinates are Finder's: points from the top-left corner of the window's content.
// `iconCentre` and `window` must agree with DMG_ICON_X/Y and DMG_WINDOW_WIDTH/HEIGHT in
// scripts/release-functions.sh; scripts/test-release-dmg.sh compares them.
import AppKit
import CoreText
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("scripts/dmg/background.tiff")

let window = CGSize(width: 640, height: 400)
let iconCentre = CGPoint(x: 144, y: 196)
// Finder pins the picture to the top-left corner and does not scale it. The spare paper
// below and to the right keeps a window that turns out a little larger from showing a
// bare strip.
let canvas = CGSize(width: 720, height: 480)

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
let ink = srgb(0.122, 0.227, 0.373) // the app icon's tile
let paper = srgb(0.965, 0.957, 0.937) // the app icon's glyph
// Finder draws the icon's name itself, near-black in the light appearance and near-white
// in the dark one. The well the icon sits in is the tone on which both can be read.
let well = srgb(0.361, 0.471, 0.588)
let muted = srgb(0.290, 0.365, 0.455)
let white = srgb(1, 1, 1)
let black = srgb(0, 0, 0)

/// WCAG relative luminance and contrast ratio.
func luminance(_ color: CGColor) -> CGFloat {
    let c = color.components!.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}
func contrast(_ a: CGColor, _ b: CGColor) -> CGFloat {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
for (name, foreground, background) in [("a white icon name on the well", white, well), ("a black icon name on the well", black, well),
                                       ("ink on paper", ink, paper), ("muted text on paper", muted, paper), ("paper on ink", paper, ink)] {
    let ratio = contrast(foreground, background)
    guard ratio >= 4.5 else { fatalError("\(name) has a contrast of \(ratio), below 4.5") }
    print(String(format: "contrast %.2f  %@", ratio, name))
}

func font(_ name: String, size: CGFloat) -> CTFont {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    guard CTFontCopyPostScriptName(font) as String == name else { fatalError("font \(name) is not installed") }
    return font
}
let bold = "SourceHanSansSC-Bold", medium = "SourceHanSansSC-Medium", regular = "SourceHanSansSC-Regular"

func draw(_ context: CGContext) {
    // Top-left origin for shapes; text is positioned through `text` below.
    func y(_ top: CGFloat) -> CGFloat { canvas.height - top }
    func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: y(top + height), width: width, height: height)
    }
    /// One line of text with its baseline at `baseline` (from the top). Returns its width.
    @discardableResult
    func text(_ string: String, _ fontName: String, _ size: CGFloat, _ color: CGColor, x: CGFloat, baseline: CGFloat, centred: Bool = false) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(fontName, size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: centred ? x - width / 2 : x, y: y(baseline))
        CTLineDraw(line, context)
        return width
    }

    context.setFillColor(paper); context.fill(CGRect(origin: .zero, size: canvas))

    let margin: CGFloat = 44
    text("安装灵译输入法", bold, 25, ink, x: margin, baseline: 62)
    text("Install RimeLingo", regular, 13, muted, x: margin + 1, baseline: 84)

    // The well: the 128 pt icon and the name Finder draws under it both fall inside.
    let wellRect = rect(iconCentre.x - 100, 112, 200, 214)
    context.addPath(CGPath(roundedRect: wellRect, cornerWidth: 24, cornerHeight: 24, transform: nil))
    context.setFillColor(well); context.fillPath()

    // Two steps to the right of the well, the first with an arrow pointing at the icon.
    let badgeX: CGFloat = 322, textX: CGFloat = 346
    let steps: [(top: CGFloat, number: String, chinese: String, english: String)] = [
        (150, "1", "双击左侧图标", "Double-click the icon on the left"),
        (226, "2", "在弹出的窗口里点「安装」", "Click Install in the window that opens"),
    ]
    for step in steps {
        context.setFillColor(ink)
        context.fillEllipse(in: rect(badgeX - 13, step.top, 26, 26))
        text(step.number, bold, 14, paper, x: badgeX, baseline: step.top + 18, centred: true)
        text(step.chinese, medium, 17, ink, x: textX, baseline: step.top + 19)
        text(step.english, regular, 12, muted, x: textX, baseline: step.top + 39)
    }
    let arrowY = y(steps[0].top + 13), tip: CGFloat = 256, tail: CGFloat = 296
    context.setStrokeColor(ink); context.setLineWidth(2.5); context.setLineCap(.round); context.setLineJoin(.round)
    context.move(to: CGPoint(x: tail, y: arrowY)); context.addLine(to: CGPoint(x: tip, y: arrowY))
    context.move(to: CGPoint(x: tip + 9, y: arrowY + 8)); context.addLine(to: CGPoint(x: tip, y: arrowY))
    context.addLine(to: CGPoint(x: tip + 9, y: arrowY - 8))
    context.strokePath()

    // What the user does not have to do, set apart by a hairline.
    context.setFillColor(ink.copy(alpha: 0.14)!)
    context.fill(rect(textX - 37, 296, window.width - margin - (textX - 37), 1))
    text("无需拖到「应用程序」，不用终端，也不用注销", regular, 12, muted, x: textX - 37, baseline: 320)
    text("No need to drag to Applications, no Terminal, no logout", regular, 10.5, muted, x: textX - 37, baseline: 337)
}

func render(scale: Int) -> CGImage {
    let context = CGContext(data: nil, width: Int(canvas.width) * scale, height: Int(canvas.height) * scale, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    draw(context)
    return context.makeImage()!
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let tiff = CGImageDestinationCreateWithURL(output as CFURL, "public.tiff" as CFString, 2, nil) else { fatalError("cannot write \(output.path)") }
for scale in [1, 2] {
    // The resolution is what tells AppKit that the larger rendering is the same size in points.
    CGImageDestinationAddImage(tiff, render(scale: scale), [
        kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5], // LZW
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(tiff) else { fatalError("cannot write \(output.path)") }
print("written: \(output.path)")
