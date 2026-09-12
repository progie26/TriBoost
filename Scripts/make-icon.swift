#!/usr/bin/env swift
// Renders TriBoost.icns. Run via Scripts/make-icon.sh — no design tool needed.
import AppKit
import CoreGraphics

// Keep in sync with Sources/TriBoost/AppIcon.swift.
func drawMark(_ cg: CGContext, _ scale: CGFloat) {
    let dotRadius: CGFloat = 0.090
    for dot in [CGPoint(x: 0.205, y: 0.740), CGPoint(x: 0.500, y: 0.800), CGPoint(x: 0.795, y: 0.740)] {
        cg.fillEllipse(in: CGRect(x: (dot.x - dotRadius) * scale, y: (dot.y - dotRadius) * scale,
                                  width: dotRadius * 2 * scale, height: dotRadius * 2 * scale))
    }
    let barWidth: CGFloat = 0.115, halfHeight: CGFloat = 0.185, midY: CGFloat = 0.335
    for tipX in [CGFloat(0.420), CGFloat(0.700)] {
        let backX = tipX - 0.235
        let p = CGMutablePath()
        p.move(to: CGPoint(x: backX * scale, y: (midY + halfHeight) * scale))
        p.addLine(to: CGPoint(x: tipX * scale, y: midY * scale))
        p.addLine(to: CGPoint(x: backX * scale, y: (midY - halfHeight) * scale))
        p.addLine(to: CGPoint(x: (backX + barWidth) * scale, y: (midY - halfHeight) * scale))
        p.addLine(to: CGPoint(x: (tipX + barWidth) * scale, y: midY * scale))
        p.addLine(to: CGPoint(x: (backX + barWidth) * scale, y: (midY + halfHeight) * scale))
        p.closeSubpath()
        cg.addPath(p); cg.fillPath()
    }
}

func renderIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                       bytesPerRow: 0, space: cs,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // macOS icon grid: the art sits inset inside the canvas.
    let inset = s * 0.09
    let side = s - inset * 2
    let squircle = CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
                          cornerWidth: side * 0.2237, cornerHeight: side * 0.2237, transform: nil)

    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1),   // graphite
        CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1),   // near black
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient,
                          start: CGPoint(x: 0, y: s),
                          end: CGPoint(x: 0, y: 0),
                          options: [])
    cg.restoreGState()

    // Hairline rim for definition on light desktops.
    cg.saveGState()
    cg.addPath(squircle)
    cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    cg.setLineWidth(max(1, s * 0.004))
    cg.strokePath()
    cg.restoreGState()

    // The mark, centred in the squircle at 56% of its width.
    cg.saveGState()
    let markSide = side * 0.56
    cg.translateBy(x: inset + (side - markSide) / 2, y: inset + (side - markSide) / 2)
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    drawMark(cg, markSide)
    cg.restoreGState()

    let image = cg.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/TriBoost.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = base * scale
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try! renderIcon(size: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}
print("wrote \(iconset)")
