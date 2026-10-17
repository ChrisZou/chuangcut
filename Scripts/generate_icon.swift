#!/usr/bin/env swift
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "ChuangCut/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func render(_ size: Int, to url: URL) throws {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let rect = CGRect(x: 80, y: 80, width: 864, height: 864)
    c.setShadow(offset: CGSize(width: 0, height: -15), blur: 30, color: CGColor(gray: 0, alpha: 0.22))
    c.setFillColor(CGColor(red: 0.12, green: 0.25, blue: 0.65, alpha: 1)); c.addPath(CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)); c.fillPath(); c.setShadow(offset: .zero, blur: 0)
    c.saveGState(); c.addPath(CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)); c.clip()
    let colors = [CGColor(red: 0.22, green: 0.80, blue: 0.77, alpha: 1), CGColor(red: 0.12, green: 0.42, blue: 0.87, alpha: 1), CGColor(red: 0.27, green: 0.18, blue: 0.65, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 900), end: CGPoint(x: 880, y: 100), options: [])
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); c.setLineWidth(5); c.stroke(rect.insetBy(dx: 5, dy: 5)); c.restoreGState()
    // A compact waveform cut through by two clean edit blades.
    c.setLineCap(.round)
    let heights: [CGFloat] = [70, 140, 240, 330, 250, 150, 240, 320, 190, 100]
    for (i, height) in heights.enumerated() {
        c.setStrokeColor(CGColor(gray: 1, alpha: i == 4 || i == 5 ? 0.38 : 0.95)); c.setLineWidth(32)
        let x = CGFloat(250 + i * 58); c.move(to: CGPoint(x: x, y: 510 - height / 2)); c.addLine(to: CGPoint(x: x, y: 510 + height / 2)); c.strokePath()
    }
    c.setStrokeColor(CGColor(gray: 1, alpha: 1)); c.setLineWidth(27)
    c.move(to: CGPoint(x: 420, y: 300)); c.addLine(to: CGPoint(x: 650, y: 725)); c.strokePath()
    for x: CGFloat in [370, 470] { c.strokeEllipse(in: CGRect(x: x - 45, y: 240, width: 90, height: 90)) }
    let image = c.makeImage()!, destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
}
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        try render(size * scale, to: root.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("Contents.json"))
