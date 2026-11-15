// Renders the GitHub social preview card (1280×640) from the app icon and the README screenshot.
// Usage: swiftc scripts/make-social-preview.swift -o build/make-social-preview && build/make-social-preview
// Run from the repository root. Writes docs/social-preview.png. Key content stays inside an 80 px border.
import AppKit

let width = 1280, height = 640
let margin: CGFloat = 80

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func loadImage(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOfFile: path) else { fatalError("Missing \(path) — run from the repo root") }
    return image
}

let icon = loadImage("Resources/AppIcon.png")
let screenshot = loadImage("docs/screenshot.png")

let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

// Background.
let canvas = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(starting: color(0x1E252E), ending: color(0x0D1116))!.draw(in: canvas, angle: -90)

// Right: the popover screenshot, full safe-area height, with rounded corners.
let shotHeight = CGFloat(height) - margin * 2
let shotWidth = shotHeight * screenshot.size.width / screenshot.size.height
let shotRect = NSRect(x: CGFloat(width) - margin - shotWidth, y: margin, width: shotWidth, height: shotHeight)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: shotRect, xRadius: 18, yRadius: 18).addClip()
screenshot.draw(in: shotRect)
NSGraphicsContext.restoreGraphicsState()

// Left: icon, name, tagline and providers, vertically centred in the remaining space.
let textWidth = shotRect.minX - margin - 48
let iconSize: CGFloat = 132
let title = NSAttributedString(string: "LimitBar", attributes: [
    .font: NSFont.systemFont(ofSize: 76, weight: .bold), .foregroundColor: color(0xFFFFFF),
])
let paragraph = NSMutableParagraphStyle()
paragraph.lineSpacing = 6
let tagline = NSAttributedString(string: "AI usage monitor for your Mac menu bar", attributes: [
    .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: color(0xE6EDF3), .paragraphStyle: paragraph,
])
let details = NSAttributedString(
    string: "Claude Code · Codex · Grok usage limits\nwith progress bars and pace tracking",
    attributes: [.font: NSFont.systemFont(ofSize: 25, weight: .regular), .foregroundColor: color(0x9DA7B3), .paragraphStyle: paragraph]
)

func height(of text: NSAttributedString) -> CGFloat {
    ceil(text.boundingRect(with: NSSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin]).height)
}
let gaps: [CGFloat] = [28, 6, 22]
let blockHeight = iconSize + height(of: title) + height(of: tagline) + height(of: details) + gaps.reduce(0, +)
var y = (CGFloat(height) + blockHeight) / 2 // top of the block; AppKit's y axis points up

y -= iconSize
// The icon PNG has a transparent margin around its plate (824 of 1024 px); offset so the plate aligns left.
let plateInset = iconSize / 824 * 100
icon.draw(in: NSRect(x: margin - plateInset, y: y - plateInset, width: iconSize + plateInset * 2, height: iconSize + plateInset * 2))
y -= gaps[0]
for (text, gap) in [(title, gaps[1]), (tagline, gaps[2]), (details, CGFloat(0))] {
    let h = height(of: text)
    y -= h
    text.draw(with: NSRect(x: margin, y: y, width: textWidth, height: h), options: [.usesLineFragmentOrigin])
    y -= gap
}

NSGraphicsContext.current = nil
let output = URL(fileURLWithPath: "docs/social-preview.png")
let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: output)
print("Wrote \(output.path)")
