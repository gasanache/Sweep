#!/usr/bin/env swift
//
//  make_icon.swift
//  Renders Sweep's app icon at every size the asset catalog needs.
//
//  Each size is drawn from scratch rather than downscaled from one 1024 px
//  master: stroke widths and the corner radius are expressed as fractions of
//  the canvas, so the 16 px icon keeps legible strokes instead of turning into
//  the grey smudge that downsampling produces.
//
//  Usage:  swift Scripts/make_icon.swift [output-directory]
//

import AppKit
import Foundation

// MARK: - Palette

private let backgroundTop = NSColor(srgbRed: 0.153, green: 0.161, blue: 0.184, alpha: 1)
private let backgroundBottom = NSColor(srgbRed: 0.055, green: 0.059, blue: 0.070, alpha: 1)
private let accent = NSColor(srgbRed: 0.949, green: 0.702, blue: 0.239, alpha: 1)
private let accentDeep = NSColor(srgbRed: 0.847, green: 0.545, blue: 0.153, alpha: 1)

// MARK: - Drawing

/// Draws the icon into a bitmap of `size` × `size` points.
private func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not create bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons sit inside their canvas rather than filling it; roughly a
    // tenth of the width on each side is what the HIG grid expects.
    let inset = size * 0.094
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.2237   // Apple's continuous-corner ratio

    let squircle = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // Plate
    context.saveGState()
    squircle.addClip()
    if let gradient = NSGradient(starting: backgroundTop, ending: backgroundBottom) {
        gradient.draw(in: plate, angle: -90)
    }

    // A soft warm glow behind the glyph gives the flat plate some depth
    // without resorting to a drop shadow, which reads badly at 16 px.
    let glowRect = plate.insetBy(dx: plate.width * 0.1, dy: plate.height * 0.1)
    if let glow = NSGradient(colors: [accent.withAlphaComponent(0.16),
                                      accent.withAlphaComponent(0.0)]) {
        glow.draw(in: NSRect(x: glowRect.minX, y: glowRect.minY - glowRect.height * 0.15,
                             width: glowRect.width, height: glowRect.height * 1.2),
                  relativeCenterPosition: NSPoint(x: 0, y: -0.15))
    }
    context.restoreGState()

    // Glyph: three sweeping strokes, longest at the top, echoing the wind
    // symbol used throughout the interface.
    let centerY = plate.midY
    let strokeWidth = plate.width * 0.072
    let hook = plate.width * 0.072

    // Lengths are chosen so that the longest stroke plus its hook still ends
    // well inside the plate: an earlier pass had the middle line running off
    // the right edge, which read as a rendering bug rather than as motion.
    let lines: [(y: CGFloat, length: CGFloat, alpha: CGFloat, curl: Bool)] = [
        (centerY + plate.height * 0.180, 0.46, 1.00, true),
        (centerY,                        0.58, 0.92, true),
        (centerY - plate.height * 0.180, 0.34, 0.62, false),
    ]

    for line in lines {
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let startX = plate.minX + plate.width * 0.185
        let endX = startX + plate.width * line.length

        path.move(to: NSPoint(x: startX, y: line.y))
        path.line(to: NSPoint(x: endX, y: line.y))

        if line.curl {
            // A three-quarter turn, not a closed loop: enough to read as moving
            // air, little enough that it stays open at 16 px.
            path.appendArc(
                withCenter: NSPoint(x: endX, y: line.y + hook),
                radius: hook, startAngle: -90, endAngle: 150, clockwise: false
            )
        }

        (line.alpha > 0.9 ? accent : accentDeep).withAlphaComponent(line.alpha).setStroke()
        path.stroke()
    }

    // Hairline rim keeps the plate from bleeding into a dark desktop.
    squircle.lineWidth = max(size * 0.004, 0.5)
    NSColor.white.withAlphaComponent(0.09).setStroke()
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Output

private let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
        + "/Sweep/Assets.xcassets/AppIcon.appiconset"

try? FileManager.default.createDirectory(atPath: outputDirectory,
                                         withIntermediateDirectories: true)

/// The classic macOS ten-image set: five sizes at 1x and 2x.
private let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let rep = renderIcon(size: variant.pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let path = outputDirectory + "/" + variant.name
    try! data.write(to: URL(fileURLWithPath: path))
}

FileHandle.standardOutput.write(
    "wrote \(variants.count) icons to \(outputDirectory)\n".data(using: .utf8)!
)
