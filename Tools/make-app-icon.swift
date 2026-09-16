#!/usr/bin/env swift
//
//  Draws the Audio Manager app icon and writes the PNGs the asset catalog expects.
//
//  The icon is code rather than a binary blob on purpose: it is the one bitmap asset
//  the app ships (AGENTS.md §6), so keeping the drawing readable means it can be
//  adjusted later without a design tool and without anyone guessing at the geometry.
//
//  Usage:  swift Tools/make-app-icon.swift AudioManager/Assets.xcassets/AppIcon.appiconset
//
//  The mark is three mixer faders at different levels: the product in one glance —
//  every app on its own level, set by hand. The fader tracks and knob shading are
//  low-contrast detail that dissolves at 16pt, leaving three bars of different
//  heights, which still says the same thing.

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry, in the 1024pt design space

private enum Design {
    /// macOS icon grid: the body sits in 824pt of a 1024pt canvas, the rest is the
    /// margin the system's shadow lives in.
    static let canvas: CGFloat = 1024
    static let bodyInset: CGFloat = 100

    /// Exponent of the superellipse used for the body. macOS corners are continuous,
    /// not circular. A plain n = 5 superellipse comes out visibly rounder than the
    /// system shape at small sizes; 5.6 keeps the sides flat enough to still read as a
    /// square at 16pt.
    static let squircleExponent: Double = 5.6

    static let trackWidth: CGFloat = 84
    static let trackGap: CGFloat = 96
    static let trackHeight: CGFloat = 486

    static let knobWidth: CGFloat = 132
    static let knobHeight: CGFloat = 46

    /// Where each fader sits, as a fraction of its track. Deliberately uneven, and
    /// deliberately not ascending — a rising staircase reads as a chart, not as control.
    static let levels: [CGFloat] = [0.74, 0.42, 0.60]
}

private func squircle(in rect: CGRect, exponent: Double = Design.squircleExponent) -> CGPath {
    let path = CGMutablePath()
    let halfWidth = rect.width / 2, halfHeight = rect.height / 2
    let steps = 2880
    for step in 0...steps {
        let angle = Double(step) / Double(steps) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let x = rect.midX + halfWidth * CGFloat(copysign(pow(abs(cosine), 2 / exponent), cosine))
        let y = rect.midY + halfHeight * CGFloat(copysign(pow(abs(sine), 2 / exponent), sine))
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

private func capsule(_ rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: min(rect.width, rect.height) / 2,
        cornerHeight: min(rect.width, rect.height) / 2,
        transform: nil
    )
}

private func gray(_ white: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(red: white, green: white, blue: white, alpha: alpha)
}

// MARK: - Drawing

private func drawIcon(in context: CGContext, pixels: CGFloat) {
    let scale = pixels / Design.canvas
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let space = CGColorSpaceCreateDeviceRGB()
    let body = CGRect(x: Design.bodyInset, y: Design.bodyInset,
                      width: Design.canvas - Design.bodyInset * 2,
                      height: Design.canvas - Design.bodyInset * 2)
    let bodyPath = squircle(in: body)

    // Body, with the drop shadow macOS icons carry.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14),
                      blur: 24,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
    context.addPath(bodyPath)
    context.setFillColor(gray(0, 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()

    // Blue, lighter at the top so the icon has a light source like every other one
    // in the Dock.
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.404, green: 0.616, blue: 1.000, alpha: 1),
            CGColor(red: 0.204, green: 0.392, blue: 0.965, alpha: 1),
            CGColor(red: 0.145, green: 0.255, blue: 0.784, alpha: 1)
        ] as CFArray,
        locations: [0, 0.55, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: []
        )
    }

    // A soft highlight in the top third, so the surface reads as slightly domed.
    if let sheen = CGGradient(
        colorsSpace: space,
        colors: [gray(1, 0.22), gray(1, 0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            sheen,
            startCenter: CGPoint(x: body.midX, y: body.maxY - body.height * 0.06),
            startRadius: 0,
            endCenter: CGPoint(x: body.midX, y: body.maxY - body.height * 0.06),
            endRadius: body.width * 0.72,
            options: []
        )
    }

    drawFaders(in: context, body: body)
    context.restoreGState()

    // Inner edge light: the thin bright line along the top of a macOS icon body. It
    // fades out before it reaches the bottom, where a real one would be in shadow.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    context.addPath(bodyPath)
    context.setLineWidth(8)
    context.replacePathWithStrokedPath()
    context.clip()
    if let edge = CGGradient(
        colorsSpace: space,
        colors: [gray(1, 0.40), gray(1, 0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            edge,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.midY),
            options: [.drawsAfterEndLocation]
        )
    }
    context.restoreGState()
}

private func drawFaders(in context: CGContext, body: CGRect) {
    let count = Design.levels.count
    let totalWidth = CGFloat(count) * Design.trackWidth + CGFloat(count - 1) * Design.trackGap
    let firstX = body.midX - totalWidth / 2
    let bottom = body.midY - Design.trackHeight / 2
    let space = CGColorSpaceCreateDeviceRGB()

    for (index, level) in Design.levels.enumerated() {
        let x = firstX + CGFloat(index) * (Design.trackWidth + Design.trackGap)
        let track = CGRect(x: x, y: bottom, width: Design.trackWidth, height: Design.trackHeight)

        // The unfilled track. Low contrast on purpose: it is detail for the large
        // sizes and is meant to disappear at 16pt.
        context.addPath(capsule(track))
        context.setFillColor(gray(1, 0.15))
        context.fillPath()

        // The part that is turned up, bottom to knob.
        let fillHeight = max(Design.trackWidth, Design.trackHeight * level)
        let fill = CGRect(x: x, y: bottom, width: Design.trackWidth, height: fillHeight)
        context.saveGState()
        context.addPath(capsule(fill))
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [gray(1, 1.0), gray(1, 0.90)] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: fill.midX, y: fill.maxY),
                end: CGPoint(x: fill.midX, y: fill.minY),
                options: []
            )
        }
        context.restoreGState()

        // The knob. Wider than the track so the mark reads as something set by hand
        // rather than a level meter, but close enough that the two merge when small.
        let knob = CGRect(
            x: fill.midX - Design.knobWidth / 2,
            y: fill.maxY - Design.knobHeight / 2,
            width: Design.knobWidth,
            height: Design.knobHeight
        )
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8),
                          blur: 16,
                          color: CGColor(red: 0.04, green: 0.08, blue: 0.30, alpha: 0.45))
        context.addPath(capsule(knob))
        context.setFillColor(gray(1, 1))
        context.fillPath()
        context.restoreGState()
    }
}

// MARK: - Output

private func makeImage(pixels: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    drawIcon(in: context, pixels: CGFloat(pixels))
    return context.makeImage()
}

private func write(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <output directory>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)

/// Point size and scale for every slot in the macOS asset catalog.
let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]

var entries: [String] = []
for slot in slots {
    let pixels = slot.points * slot.scale
    let suffix = slot.scale == 1 ? "" : "@\(slot.scale)x"
    let name = "icon_\(slot.points)x\(slot.points)\(suffix).png"
    guard let image = makeImage(pixels: pixels),
          write(image, to: outputDirectory.appendingPathComponent(name)) else {
        FileHandle.standardError.write(Data("failed to write \(name)\n".utf8))
        exit(1)
    }
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.points)x\(slot.points)"
        }
    """)
    print("wrote \(name) (\(pixels)×\(pixels))")
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: outputDirectory.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("wrote Contents.json")
