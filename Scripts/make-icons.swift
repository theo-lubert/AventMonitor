#!/usr/bin/env swift
// Builds the app icon and the menu bar template icon from Resources/camera.svg.
//
//   swift Scripts/make-icons.swift <camera.svg> <Assets.xcassets>

import AppKit

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default

guard let glyph = NSImage(contentsOf: svgURL) else {
    fatalError("Cannot read \(svgURL.path)")
}
let svgSource = try! String(contentsOf: svgURL, encoding: .utf8)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func png(_ size: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: App icon: white camera glyph on a night-blue tile with a warm glow

func drawAppIcon(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.3))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x2A3658))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [color(0x4A5D8F), color(0x1E2742)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft night-light glow behind the camera.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFB36B, 0.55), color(0xFFB36B, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 340, options: [])
    ctx.restoreGState()

    // The glyph fills the 256 viewBox; scale it to sit inside the tile.
    let side: CGFloat = 700
    let rect = CGRect(x: 512 - side / 2, y: 512 - side / 2 - 6, width: side, height: side)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x0B1020, 0.45))
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    glyph.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}

// MARK: Write the asset catalog

try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
try! #"{"info":{"author":"xcode","version":1}}"#
    .write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try? fm.removeItem(at: iconSet)
try! fm.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! png(points * scale, drawAppIcon).write(to: iconSet.appendingPathComponent(name))
        images.append(#"{"idiom":"mac","size":"\#(points)x\#(points)","scale":"\#(scale)x","filename":"\#(name)"}"#)
    }
}
try! #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
    .write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// Menu bar: the same SVG as a vector template image, cropped to the camera
// (content spans x 85…171, y 16…240 in the 256 viewBox) and sized for an
// 18 pt menu bar.
let crop = (x: 80.0, y: 12.0, w: 96.0, h: 232.0)
let height = 18.0
let width = (height * crop.w / crop.h * 100).rounded() / 100
var menuSVG = svgSource
    .replacingOccurrences(of: #"viewBox="0 0 256 256""#, with: #"viewBox="\#(crop.x) \#(crop.y) \#(crop.w) \#(crop.h)""#)
    .replacingOccurrences(of: #"width="256""#, with: #"width="\#(width)""#)
    .replacingOccurrences(of: #"height="256""#, with: #"height="\#(height)""#)
menuSVG = menuSVG.replacingOccurrences(of: "#FFFFFF", with: "#000000")
let glyphSet = assets.appendingPathComponent("MenuBarIcon.imageset")
try? fm.removeItem(at: glyphSet)
try! fm.createDirectory(at: glyphSet, withIntermediateDirectories: true)
try! menuSVG.write(to: glyphSet.appendingPathComponent("menubar.svg"), atomically: true, encoding: .utf8)
try! #"{"images":[{"idiom":"universal","filename":"menubar.svg"}],"info":{"author":"xcode","version":1},"properties":{"preserves-vector-representation":true,"template-rendering-intent":"template"}}"#
    .write(to: glyphSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let accent = assets.appendingPathComponent("AccentColor.colorset")
try? fm.createDirectory(at: accent, withIntermediateDirectories: true)
try! #"{"colors":[{"idiom":"universal","color":{"color-space":"srgb","components":{"red":"0.910","green":"0.560","blue":"0.290","alpha":"1.000"}}}],"info":{"author":"xcode","version":1}}"#
    .write(to: accent.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// Previews for review.
let build = assets.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Build")
try? fm.createDirectory(at: build, withIntermediateDirectories: true)
try! png(1024, drawAppIcon).write(to: build.appendingPathComponent("icon-preview.png"))
if let menu = NSImage(data: Data(menuSVG.utf8)) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 72, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.92, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 120, height: 72).fill()
    menu.draw(in: NSRect(x: 60 - width * 2, y: 0, width: width * 4, height: 72))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: build.appendingPathComponent("menubar-preview.png"))
}
print("Icons written to \(assets.path)")
