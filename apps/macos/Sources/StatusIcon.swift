// Menu bar icon: a light bar, 18 × 18 pt template image, drawn in code.

import AppKit

enum StatusIcon {
    static func image(_ state: AppModel.IconState) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let bar = NSBezierPath(roundedRect: NSRect(x: 2, y: 2.5, width: 14, height: 3.5), xRadius: 1.75, yRadius: 1.75)
            bar.lineWidth = 1.2
            switch state {
            case .on:
                bar.fill()
                rays()
            case .off:
                bar.stroke()
            case .mirroring:
                bar.fill()
                let screen = NSBezierPath(roundedRect: NSRect(x: 5, y: 9, width: 8, height: 6), xRadius: 1, yRadius: 1)
                screen.lineWidth = 1.2
                screen.stroke()
            case .unreachable:
                bar.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 16))
                slash.line(to: NSPoint(x: 15, y: 1))
                slash.lineWidth = 1.4
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Light falling down from the bar.
    private static func rays() {
        for (from, to) in [(NSPoint(x: 9, y: 8.5), NSPoint(x: 9, y: 14.5)),
                           (NSPoint(x: 5, y: 8.5), NSPoint(x: 3, y: 13.5)),
                           (NSPoint(x: 13, y: 8.5), NSPoint(x: 15, y: 13.5))] {
            let ray = NSBezierPath()
            ray.move(to: from)
            ray.line(to: to)
            ray.lineWidth = 1.4
            ray.lineCapStyle = .round
            ray.stroke()
        }
    }
}
