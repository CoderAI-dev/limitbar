// Renders the app icon: two usage bars of different heights, the taller one running past its
// pace tick into red. Writes a 1024 px PNG to the path given as the first argument.
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

// Two bars: (fill fraction, pace fraction). The second runs past its pace tick, shown in red.
let bars: [(fill: CGFloat, pace: CGFloat?)] = [(0.42, nil), (0.82, 0.58)]
let barWidth: CGFloat = 170, gap: CGFloat = 96, barHeight: CGFloat = 560
let totalWidth = barWidth * CGFloat(bars.count) + gap * CGFloat(bars.count - 1)
let green = color(0x34C759), red = color(0xFF453A)

for (index, bar) in bars.enumerated() {
    let x = (size - totalWidth) / 2 + CGFloat(index) * (barWidth + gap)
    let track = NSRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight)
    let trackPath = NSBezierPath(roundedRect: track, xRadius: 44, yRadius: 44)
    color(0xFFFFFF, alpha: 0.10).setFill()
    trackPath.fill()

    NSGraphicsContext.saveGraphicsState()
    trackPath.addClip()
    let paceHeight = barHeight * (bar.pace ?? bar.fill)
    green.setFill()
    NSRect(x: x, y: track.minY, width: barWidth, height: min(paceHeight, barHeight * bar.fill)).fill()
    if let pace = bar.pace, bar.fill > pace {
        red.setFill()
        NSRect(x: x, y: track.minY + paceHeight, width: barWidth, height: barHeight * (bar.fill - pace)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    if bar.pace != nil {
        // The pace tick, slightly wider than the bar.
        color(0xFFFFFF).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 22, y: track.minY + paceHeight - 9, width: barWidth + 44, height: 18), xRadius: 9, yRadius: 9).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
