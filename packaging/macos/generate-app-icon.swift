#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon.swift ICONSET\n".utf8))
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(size: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size), y: CGFloat(size))

    let outer = CGPath(
        roundedRect: CGRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88),
        cornerWidth: 0.205,
        cornerHeight: 0.205,
        transform: nil
    )
    context.addPath(outer)
    context.setFillColor(CGColor(red: 0.985, green: 0.78, blue: 0.12, alpha: 1))
    context.fillPath()

    let sheet = CGPath(
        roundedRect: CGRect(x: 0.16, y: 0.14, width: 0.68, height: 0.72),
        cornerWidth: 0.105,
        cornerHeight: 0.105,
        transform: nil
    )
    context.addPath(sheet)
    context.setFillColor(CGColor(red: 1, green: 0.995, blue: 0.965, alpha: 1))
    context.fillPath()

    context.saveGState()
    context.addPath(sheet)
    context.clip()
    context.setFillColor(CGColor(red: 0.985, green: 0.78, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: 0.16, y: 0.70, width: 0.68, height: 0.16))
    context.restoreGState()

    context.setStrokeColor(CGColor(red: 0.80, green: 0.77, blue: 0.67, alpha: 0.72))
    context.setLineCap(.round)
    context.setLineWidth(0.027)
    for y in [0.61, 0.53] as [CGFloat] {
        context.move(to: CGPoint(x: 0.27, y: y))
        context.addLine(to: CGPoint(x: 0.73, y: y))
        context.strokePath()
    }

    let ink = CGColor(red: 0.105, green: 0.12, blue: 0.145, alpha: 1)
    context.setStrokeColor(ink)
    context.setLineWidth(0.064)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 0.30, y: 0.42))
    context.addLine(to: CGPoint(x: 0.40, y: 0.34))
    context.addLine(to: CGPoint(x: 0.30, y: 0.26))
    context.strokePath()
    context.move(to: CGPoint(x: 0.48, y: 0.26))
    context.addLine(to: CGPoint(x: 0.66, y: 0.26))
    context.strokePath()

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

for (name, size) in variants {
    try drawIcon(size: size, to: output.appendingPathComponent(name))
}
