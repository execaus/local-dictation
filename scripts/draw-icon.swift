import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift draw-icon.swift OUTPUT.png\n", stderr)
    exit(1)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create icon canvas\n", stderr)
    exit(1)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high
graphics.shouldAntialias = true

let tile = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960),
                        xRadius: 218, yRadius: 218)
NSGradient(starting: color(0.075, 0.105, 0.25), ending: color(0.28, 0.20, 0.54))!
    .draw(in: tile, angle: 135)

let glow = NSBezierPath(ovalIn: NSRect(x: 132, y: 364, width: 760, height: 630))
color(0.25, 0.65, 0.94, 0.12).setFill()
glow.fill()

let glass = NSBezierPath(roundedRect: NSRect(x: 132, y: 132, width: 760, height: 760),
                         xRadius: 200, yRadius: 200)
NSGradient(starting: color(0.88, 0.96, 1.0, 0.16),
           ending: color(0.55, 0.81, 1.0, 0.045))!
    .draw(in: glass, angle: 90)
glass.lineWidth = 3
color(1, 1, 1, 0.24).setStroke()
glass.stroke()

let bars: [(CGFloat, CGFloat)] = [
    (280, 176), (346, 304), (412, 432), (478, 512),
    (544, 432), (610, 304), (676, 176),
]
for (x, height) in bars {
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: 512 - height / 2,
                                                width: 48, height: height),
                           xRadius: 24, yRadius: 24)
    NSGradient(starting: color(0.94, 1, 1), ending: color(0.37, 0.91, 0.92))!
        .draw(in: bar, angle: 90)
}

let recordingHalo = NSBezierPath(ovalIn: NSRect(x: 728, y: 730, width: 134, height: 134))
color(0.98, 0.40, 0.45, 0.17).setFill()
recordingHalo.fill()
let recordingDot = NSBezierPath(ovalIn: NSRect(x: 755, y: 757, width: 80, height: 80))
color(1.0, 0.43, 0.47).setFill()
recordingDot.fill()
recordingDot.lineWidth = 3
color(1, 1, 1, 0.55).setStroke()
recordingDot.stroke()

graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode icon PNG\n", stderr)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
