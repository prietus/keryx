// Renders the app icon into the asset catalog:
//   swift Config/icon.swift Keryx/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

// macOS icon template: 1024 canvas, 824 squircle-ish tile centred, soft shadow.
struct Variant { let name: String; let top: NSColor; let bottom: NSColor; let glyph: String; let ink: NSColor; let serif: Bool }

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ v: Variant, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

    // Shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    v.bottom.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Pastel gradient, light from the top.
    NSGradient(starting: v.top, ending: v.bottom)!.draw(in: path, angle: -90)
    // A faint inner highlight along the top edge.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The kappa, as an outline centred on its own ink (optically a touch high).
    let base = NSFont.systemFont(ofSize: 560 * s, weight: v.serif ? .medium : .semibold)
    let font = v.serif ? NSFont(descriptor: base.fontDescriptor.withDesign(.serif)!, size: 560 * s)! : base
    var unichars = Array(v.glyph.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
    CTFontGetGlyphsForCharacters(font as CTFont, &unichars, &glyphs, unichars.count)
    let outline = CTFontCreatePathForGlyph(font as CTFont, glyphs[0], nil)!
    let box = outline.boundingBoxOfPath
    var move = CGAffineTransform(translationX: tile.midX - box.midX, y: tile.midY - box.midY + 12 * s)
    let placed = outline.copy(using: &move)!
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.addPath(placed)
    ctx.setFillColor(v.ink.cgColor)
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants = [
    Variant(name: "a-lavanda", top: rgb(0xE4DDFB), bottom: rgb(0xB9C6F4), glyph: "κ", ink: rgb(0x3B3F8F), serif: true),
    Variant(name: "b-melocoton", top: rgb(0xFFE3D3), bottom: rgb(0xF7B9C4), glyph: "Κ", ink: rgb(0x8E3B52), serif: false),
    Variant(name: "c-menta", top: rgb(0xD8F3EA), bottom: rgb(0xA9D8E8), glyph: "κ", ink: rgb(0x1F5E66), serif: true),
]
let chosen = variants[0]
let out = CommandLine.arguments[1]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let data = render(chosen, size: px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(px).png"))
}
print("ok")
