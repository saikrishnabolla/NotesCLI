import AppKit

enum NotesMenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let page = NSBezierPath()
            page.move(to: NSPoint(x: 4, y: 1.75))
            page.line(to: NSPoint(x: 10.5, y: 1.75))
            page.line(to: NSPoint(x: 15.5, y: 6.75))
            page.line(to: NSPoint(x: 15.5, y: 14.75))
            page.curve(to: NSPoint(x: 14, y: 16.25), controlPoint1: NSPoint(x: 15.5, y: 15.7), controlPoint2: NSPoint(x: 14.95, y: 16.25))
            page.line(to: NSPoint(x: 4, y: 16.25))
            page.curve(to: NSPoint(x: 2.5, y: 14.75), controlPoint1: NSPoint(x: 3.05, y: 16.25), controlPoint2: NSPoint(x: 2.5, y: 15.7))
            page.line(to: NSPoint(x: 2.5, y: 3.25))
            page.curve(to: NSPoint(x: 4, y: 1.75), controlPoint1: NSPoint(x: 2.5, y: 2.3), controlPoint2: NSPoint(x: 3.05, y: 1.75))
            page.close()
            page.move(to: NSPoint(x: 10.5, y: 1.75))
            page.line(to: NSPoint(x: 10.5, y: 6.75))
            page.line(to: NSPoint(x: 15.5, y: 6.75))
            page.lineWidth = 1.3
            page.lineJoinStyle = .round
            page.stroke()

            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: 5.5, y: 8.75))
            prompt.line(to: NSPoint(x: 8, y: 11))
            prompt.line(to: NSPoint(x: 5.5, y: 13.25))
            prompt.move(to: NSPoint(x: 9.75, y: 13.25))
            prompt.line(to: NSPoint(x: 12.5, y: 13.25))
            prompt.lineWidth = 1.5
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notes CLI"
        return image
    }
}
