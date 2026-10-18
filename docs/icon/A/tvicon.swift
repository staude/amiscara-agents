// Renders the Apple TV icon and Top Shelf images from concept A (#82, #130).
// Icon Composer has no tvOS, so this draws the layers of layers.py with
// CoreGraphics in the dark colours of README.md and writes the brand assets
// into the app's asset catalog.
//
//     swift docs/icon/A/tvicon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized
let catalog = root.appending(path: "apps/AmiscaraAgents/AmiscaraAgents/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Geometry of layers.py on its 1024 canvas (y down).
let paneW: CGFloat = 560, paneH: CGFloat = 430, paneR: CGFloat = 72
let panes: [(CGFloat, CGFloat)] = (0..<3).map { (327 - CGFloat($0) * 95, 200 + CGFloat($0) * 95) }
let paneColors = [color(0x2BB3A3, 0.22), color(0x2FD1A5, 0.34), color(0x14A08C, 0.88)]
/// Bounding box of the composition on the 1024 canvas.
let box = CGRect(x: 137, y: 200, width: 750, height: 620)

enum Layer { case back, middle, front, flat }

/// Draws `layer` into a w×h canvas, the composition centred at `fill` of the
/// height (and shifted by `offsetX` of the width for the Top Shelf).
func render(_ layer: Layer, w: Int, h: Int, fill: CGFloat, offsetX: CGFloat = 0) -> CGImage {
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // y down like the SVG
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    if layer == .back || layer == .flat {
        let gradient = CGGradient(colorsSpace: nil, colors: [color(0x0B2A2E), color(0x04161A)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
    }
    let scale = CGFloat(h) * fill / box.height
    let originX = (CGFloat(w) - box.width * scale) / 2 + CGFloat(w) * offsetX - box.minX * scale
    let originY = (CGFloat(h) - box.height * scale) / 2 - box.minY * scale
    ctx.translateBy(x: originX, y: originY)
    ctx.scaleBy(x: scale, y: scale)
    if layer == .middle || layer == .flat {
        for (index, (x, y)) in panes.enumerated() {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: paneW, height: paneH), cornerWidth: paneR, cornerHeight: paneR, transform: nil))
            ctx.setFillColor(paneColors[index])
            ctx.fillPath()
        }
    }
    if layer == .front || layer == .flat {
        let (fx, fy) = panes[2]
        let px = fx + 120, py = fy + 215
        ctx.setStrokeColor(color(0xF2FFFB))
        ctx.setLineWidth(46)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: px, y: py - 85))
        ctx.addLine(to: CGPoint(x: px + 95, y: py))
        ctx.addLine(to: CGPoint(x: px, y: py + 85))
        ctx.strokePath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: px + 150, y: py + 62, width: 140, height: 46), cornerWidth: 23, cornerHeight: 23, transform: nil))
        ctx.setFillColor(color(0xF2FFFB))
        ctx.fillPath()
        let dot = CGPoint(x: 327 + paneW - 82, y: 200 + 82)
        ctx.addEllipse(in: CGRect(x: dot.x - 38, y: dot.y - 38, width: 76, height: 76))
        ctx.setFillColor(color(0xFF9F0A))
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func json(_ object: Any, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

let info = ["author": "xcode", "version": 1] as [String: Any]
try? FileManager.default.removeItem(at: catalog)

/// An image stack with back, middle and front layer at the given sizes.
func imageStack(_ name: String, sizes: [(scale: String, w: Int, h: Int)]) {
    let stack = catalog.appending(path: "\(name).imagestack")
    let layers: [(String, Layer)] = [("Front", .front), ("Middle", .middle), ("Back", .back)]
    json(["info": info, "layers": layers.map { ["filename": "\($0.0).imagestacklayer"] }], to: stack.appending(path: "Contents.json"))
    for (layerName, layer) in layers {
        let dir = stack.appending(path: "\(layerName).imagestacklayer")
        json(["info": info], to: dir.appending(path: "Contents.json"))
        let set = dir.appending(path: "Content.imageset")
        var images: [[String: String]] = []
        for size in sizes {
            let file = "\(layerName.lowercased())@\(size.scale).png"
            write(render(layer, w: size.w, h: size.h, fill: 0.78), to: set.appending(path: file))
            images.append(["filename": file, "idiom": "tv", "scale": size.scale])
        }
        json(["images": images, "info": info], to: set.appending(path: "Contents.json"))
    }
}

/// A flat Top Shelf image, the composition left of centre.
func topShelf(_ name: String, w: Int, h: Int) {
    let set = catalog.appending(path: "\(name).imageset")
    var images: [[String: String]] = []
    for (scale, factor) in [("1x", 1), ("2x", 2)] {
        let file = "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))@\(scale).png"
        write(render(.flat, w: w * factor, h: h * factor, fill: 0.7, offsetX: -0.28), to: set.appending(path: file))
        images.append(["filename": file, "idiom": "tv", "scale": scale])
    }
    json(["images": images, "info": info], to: set.appending(path: "Contents.json"))
}

/// Full-screen backdrops for the Top Shelf, one per agent state: the
/// extension only picks one, since drawing at run time exceeds its memory.
func shelfBackdrop(state: String, colour: CGColor) {
    let w = 1920, h = 1080
    let base = render(.flat, w: w, h: h, fill: 0.62, offsetX: 0.2)
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
    // A bar in the state colour along the top edge (y up here).
    ctx.setFillColor(colour)
    ctx.fill(CGRect(x: 0, y: h - 18, width: w, height: 18))
    let dir = root.appending(path: "apps/AmiscaraAgents/TopShelf/Resources")
    let url = dir.appending(path: "shelf-\(state).jpg")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

shelfBackdrop(state: "blocked", colour: color(0xFF9F0A))
shelfBackdrop(state: "working", colour: color(0x0A84FF))
shelfBackdrop(state: "done", colour: color(0x30D158))

imageStack("App Icon", sizes: [("1x", 400, 240), ("2x", 800, 480)])
imageStack("App Icon - App Store", sizes: [("1x", 1280, 768)])
topShelf("Top Shelf Image", w: 1920, h: 720)
topShelf("Top Shelf Image Wide", w: 2320, h: 720)
json([
    "assets": [
        ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
        ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
        ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
        ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
    ],
    "info": info,
], to: catalog.appending(path: "Contents.json"))
print("ok: \(catalog.path)")
