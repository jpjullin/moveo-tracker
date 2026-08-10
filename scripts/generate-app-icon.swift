import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon.swift OUTPUT.iconset\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1_024)
]

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let side = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.setShouldAntialias(true)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    let inset = side * 0.055
    let tileRect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: side * 0.215, yRadius: side * 0.215)
    NSColor(calibratedRed: 0.055, green: 0.47, blue: 0.98, alpha: 1).setFill()
    tile.fill()

    let pointSize = side * 0.60
    let baseConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    let whiteConfiguration = NSImage.SymbolConfiguration(paletteColors: [.white])
    let configuration = baseConfiguration.applying(whiteConfiguration)
    guard let hand = NSImage(
        systemSymbolName: "hand.raised.fill",
        accessibilityDescription: "Hand Vision Native"
    )?.withSymbolConfiguration(configuration) else {
        throw CocoaError(.featureUnsupported)
    }

    let target = NSRect(x: side * 0.205, y: side * 0.155, width: side * 0.59, height: side * 0.69)
    let scale = min(target.width / hand.size.width, target.height / hand.size.height)
    let drawSize = NSSize(width: hand.size.width * scale, height: hand.size.height * scale)
    let drawRect = NSRect(
        x: target.midX - drawSize.width / 2,
        y: target.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    hand.draw(in: drawRect)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for variant in variants {
    let data = try renderIcon(pixels: variant.pixels)
    try data.write(to: outputDirectory.appendingPathComponent(variant.name), options: .atomic)
}
