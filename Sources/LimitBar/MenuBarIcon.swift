import AppKit
import LimitBarCore

/// Draws the menu bar label: per provider a letter plus a vertical bar filled to its worst usage.
/// The result is a vector-backed template image, so it is crisp at any scale and adapts to the menu bar.
enum MenuBarIcon {
    struct Item {
        let id: ProviderID
        let percent: Double?
        /// The percent is from before the latest failed refresh; the bar is drawn dimmed.
        let stale: Bool
    }

    private static let height: CGFloat = 18
    private static let barSize = CGSize(width: 5, height: 13)
    private static let letterGap: CGFloat = 1.5
    private static let groupGap: CGFloat = 5
    private static var font: NSFont { NSFont.systemFont(ofSize: 10, weight: .semibold) }

    static func image(for items: [Item]) -> NSImage {
        let letters = items.map { NSAttributedString(string: $0.id.letter, attributes: [.font: font, .foregroundColor: NSColor.black]) }
        let groupWidths = letters.map { ceil($0.size().width) + letterGap + barSize.width }
        let width = groupWidths.reduce(0, +) + groupGap * CGFloat(max(items.count - 1, 0))

        let image = NSImage(size: CGSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, item) in items.enumerated() {
                let letter = letters[index]
                let letterSize = letter.size()
                letter.draw(at: CGPoint(x: x, y: (height - letterSize.height) / 2))
                x += ceil(letterSize.width) + letterGap
                drawBar(at: CGPoint(x: x, y: (height - barSize.height) / 2), percent: item.percent, stale: item.stale)
                x += barSize.width + groupGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawBar(at origin: CGPoint, percent: Double?, stale: Bool) {
        let alpha: CGFloat = percent == nil || stale ? 0.35 : 1
        let lineWidth: CGFloat = 1
        let track = CGRect(origin: origin, size: barSize).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let outline = NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5)
        outline.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(alpha).setStroke()
        outline.stroke()

        guard let percent, percent > 0 else { return }
        let inner = CGRect(origin: origin, size: barSize).insetBy(dx: 1.5, dy: 1.5)
        let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * percent / 100)
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 0.5, yRadius: 0.5).fill()
    }

    static func accessibilityLabel(for items: [Item]) -> String {
        items.map { item in
            let value = item.percent.map { "\(Int($0.rounded())) percent" } ?? "no data"
            return "\(item.id.displayName) \(value)\(item.stale ? ", stale" : "")"
        }.joined(separator: ", ")
    }
}
