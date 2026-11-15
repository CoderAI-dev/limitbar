// Renders the app icon: two horizontal usage bars of different lengths, the longer one running
// past its pace tick into red. Writes a 1024 px PNG to the path given as the first argument.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the standard macOS icon plate (824 pt rounded square centred on a 1024 canvas).
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x2B3440), ending: color(0x11161C))!.draw(in: platePath, angle: -90)
color(0xFFFFFF, alpha: 0.08).setStroke()
platePath.lineWidth = 4
platePath.stroke()

// Two horizontal bars, top to bottom: (fill fraction, pace fraction). The second runs past its
// pace tick, shown in red — the same look as the bars in the app's popover.
let bars: [(fill: CGFloat, pace: CGFloat?)] = [(0.42, nil), (0.82, 0.58)]
let barHeight: CGFloat = 150, gap: CGFloat = 96, barWidth: CGFloat = 580
let totalHeight = barHeight * CGFloat(bars.count) + gap * CGFloat(bars.count - 1)
let green = color(0x34C759), red = color(0xFF453A)

for (index, bar) in bars.enumerated() {
    // AppKit's y axis points up, so the first bar is drawn at the top.
    let y = (size + totalHeight) / 2 - barHeight - CGFloat(index) * (barHeight + gap)
    let track = NSRect(x: (size - barWidth) / 2, y: y, width: barWidth, height: barHeight)
    let trackPath = NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2)
    color(0xFFFFFF, alpha: 0.10).setFill()
    trackPath.fill()

    NSGraphicsContext.saveGraphicsState()
    trackPath.addClip()
    let paceWidth = barWidth * (bar.pace ?? bar.fill)
    green.setFill()
    NSRect(x: track.minX, y: y, width: min(paceWidth, barWidth * bar.fill), height: barHeight).fill()
    if let pace = bar.pace, bar.fill > pace {
        red.setFill()
        NSRect(x: track.minX + paceWidth, y: y, width: barWidth * (bar.fill - pace), height: barHeight).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    if bar.pace != nil {
        // The pace tick, slightly taller than the bar.
        color(0xFFFFFF).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX + paceWidth - 9, y: y - 24, width: 18, height: barHeight + 48), xRadius: 9, yRadius: 9).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
