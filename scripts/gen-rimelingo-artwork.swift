#!/usr/bin/env swift
// Renders RimeLingo's own artwork from the glyph 「灵」 so that nothing bundled in the
// app shows the old brand:
//   Apps/RimeLingo/Resources/RimeLingo.pdf                 input source (menu bar) icon
//   Apps/Shared/Assets.xcassets/AppIcon.appiconset/*.png   app icon, ten sizes
//   Apps/Shared/Assets.xcassets/BrandSquare.imageset/*.png square mark, light and dark
//   Apps/Shared/Assets.xcassets/BrandLockup.imageset/*.png mark plus both names, light and dark
//
// Glyph outlines come from Source Han Sans SC (SIL OFL 1.1), which must be installed.
// The font itself is not kept in the repository.
//   swift scripts/gen-rimelingo-artwork.swift [glyph-font-postscript-name]
import AppKit
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let glyphFontName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "SourceHanSansSC-Bold"
let wordFontName = "SourceHanSansSC-Heavy"
let character: UniChar = 0x7075 // 灵
let wordmark = "RimeLingo"
let chineseName = "灵译输入法"

let ink = CGColor(srgbRed: 0.122, green: 0.227, blue: 0.373, alpha: 1) // app icon background
let paper = CGColor(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 1) // app icon glyph
let text = CGColor(srgbRed: 0.133, green: 0.133, blue: 0.125, alpha: 1)
let black = CGColor(gray: 0, alpha: 1)
let white = CGColor(gray: 1, alpha: 1)

func font(_ name: String, size: CGFloat) -> CTFont {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    guard CTFontCopyPostScriptName(font) as String == name else { fatalError("font \(name) is not installed") }
    return font
}

/// The glyph outline scaled so its ink is `height` tall and centred on `centre`.
func glyph(height: CGFloat, centre: CGPoint) -> CGPath {
    let base = font(glyphFontName, size: 1000)
    var ch = character
    var g: CGGlyph = 0
    guard CTFontGetGlyphsForCharacters(base, &ch, &g, 1), g != 0, let outline = CTFontCreatePathForGlyph(base, g, nil) else {
        fatalError("glyph is missing from \(glyphFontName)")
    }
    let box = outline.boundingBoxOfPath
    let scale = height / box.height
    var transform = CGAffineTransform(translationX: centre.x - box.midX * scale, y: centre.y - box.midY * scale).scaledBy(x: scale, y: scale)
    return outline.copy(using: &transform)!
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func png(width: Int, height: Int, to path: String, draw: (CGContext) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    draw(context)
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(path))
}

/// A filled tile with the glyph drawn on top in `glyphColor`, or cut out when nil.
func mark(_ context: CGContext, tile: CGRect, radius: CGFloat, tileColor: CGColor, glyphColor: CGColor?, glyphHeight: CGFloat) {
    let shape = glyph(height: glyphHeight, centre: CGPoint(x: tile.midX, y: tile.midY))
    if let glyphColor {
        context.addPath(rounded(tile, radius: radius)); context.setFillColor(tileColor); context.fillPath()
        context.addPath(shape); context.setFillColor(glyphColor); context.fillPath(using: .winding)
    } else {
        // Merge overlapping strokes (non-zero) before cutting, then fill the remainder.
        context.addPath(rounded(tile, radius: radius).subtracting(shape, using: .winding))
        context.setFillColor(tileColor); context.fillPath(using: .evenOdd)
    }
}

// MARK: Input source icon: the glyph cut out of a 22×16 pt rounded rectangle, the shape
// macOS uses for its own input sources. One black fill; the system tints it as a template.
do {
    let width: CGFloat = 22, height: CGFloat = 16
    let icon = rounded(CGRect(x: 0, y: 0, width: width, height: height), radius: 3.5)
        .subtracting(glyph(height: 11.4, centre: CGPoint(x: width / 2, y: height / 2)), using: .winding)
    var box = CGRect(x: 0, y: 0, width: width, height: height)
    let url = root.appendingPathComponent("Apps/RimeLingo/Resources/RimeLingo.pdf")
    let pdf = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "scripts/gen-rimelingo-artwork.swift"] as CFDictionary)!
    pdf.beginPDFPage(nil)
    pdf.addPath(icon); pdf.setFillColor(black); pdf.fillPath(using: .evenOdd)
    pdf.endPDFPage(); pdf.closePDF()
}

// MARK: App icon. The tile is inset like other macOS icons (824 of 1024).
let assets = "Apps/Shared/Assets.xcassets"
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    try png(width: pixels, height: pixels, to: "\(assets)/AppIcon.appiconset/icon_\(points)x\(points)@\(scale)x.png") { context in
        let unit = CGFloat(pixels) / 1024
        context.scaleBy(x: unit, y: unit)
        mark(context, tile: CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185, tileColor: ink, glyphColor: paper, glyphHeight: 520)
    }
}

// MARK: Square mark, shown small in the settings sidebar and onboarding.
for (name, tile, glyphColor) in [("light", black, white), ("dark", white, black)] {
    try png(width: 1024, height: 1024, to: "\(assets)/BrandSquare.imageset/\(name).png") { context in
        mark(context, tile: CGRect(x: 0, y: 0, width: 1024, height: 1024), radius: 210, tileColor: tile, glyphColor: glyphColor, glyphHeight: 640)
    }
}

// MARK: Lockup: the mark followed by both names, on a transparent background.
for (name, tile, glyphColor, wordColor) in [("light", ink, Optional(paper), text), ("dark", white, nil, white)] {
    try png(width: 1084, height: 400, to: "\(assets)/BrandLockup.imageset/\(name).png") { context in
        mark(context, tile: CGRect(x: 56, y: 72, width: 256, height: 256), radius: 58, tileColor: tile, glyphColor: glyphColor, glyphHeight: 160)
        // Latin wordmark above the Chinese name, both left-aligned to the same edge.
        for (string, fontName, size, centreY) in [(wordmark, wordFontName, CGFloat(112), CGFloat(248)), (chineseName, glyphFontName, CGFloat(66), CGFloat(124))] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(fontName, size: size),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): wordColor
            ]))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textPosition = CGPoint(x: 364 - bounds.minX, y: centreY - bounds.midY)
            CTLineDraw(line, context)
        }
    }
}

print("artwork written: 灵 in \(glyphFontName), wordmark in \(wordFontName)")
