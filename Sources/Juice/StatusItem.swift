import AppKit

/// The menu bar item: a small time stacked over a small battery glyph, drawn as one image.
@MainActor
enum StatusItemContent {
    enum State { case normal, charging, low }

    private static var lastKey = ""

    static func apply(_ s: BatterySnapshot, to button: NSStatusBarButton) {
        let state = State(s)
        let key = "\(title(s))|\(s.percent)|\(state)"
        guard key != lastKey else { return }
        lastKey = key
        button.title = ""
        button.image = image(title: title(s), percent: s.percent, state: state)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(accessibilityLabel(s))
    }

    private static func title(_ s: BatterySnapshot) -> String {
        if s.isCharging, let m = s.minutesToFull { return hm(m) }
        if !s.isPluggedIn, let m = s.minutesToEmpty { return hm(m) }
        return "\(s.percent)%"
    }

    private static func hm(_ minutes: Int) -> String {
        "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    private static func accessibilityLabel(_ s: BatterySnapshot) -> String {
        if s.isCharging, let m = s.minutesToFull { return "Battery \(s.percent)%, \(m / 60) hours \(m % 60) minutes until full" }
        if !s.isPluggedIn, let m = s.minutesToEmpty { return "Battery \(s.percent)%, \(m / 60) hours \(m % 60) minutes left" }
        return "Battery \(s.percent)%"
    }

    private static func image(title: String, percent: Int, state: State) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let glyph = NSSize(width: 20, height: 9)
        let size = NSSize(width: ceil(max(textWidth, glyph.width + 2)), height: 20)

        let image = NSImage(size: size, flipped: false) { _ in
            let ink: NSColor = state == .low ? .systemRed : .labelColor

            // Time, top half.
            let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
            text.draw(at: NSPoint(x: (size.width - textWidth) / 2, y: 9.5))

            // Battery, bottom half.
            let x0 = (size.width - glyph.width) / 2
            let body = NSRect(x: x0 + 0.5, y: 0.5, width: 17, height: 8)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.4, yRadius: 2.4)
            outline.lineWidth = 1
            ink.withAlphaComponent(state == .low ? 0.8 : 0.5).setStroke()
            outline.stroke()

            let tip = NSBezierPath()
            tip.move(to: NSPoint(x: x0 + 19, y: 3.2))
            tip.line(to: NSPoint(x: x0 + 19, y: 5.8))
            tip.lineWidth = 1.2
            tip.lineCapStyle = .round
            ink.withAlphaComponent(0.45).setStroke()
            tip.stroke()

            let fillWidth = max(1.5, 14 * CGFloat(percent) / 100)
            let fill = NSBezierPath(roundedRect: NSRect(x: x0 + 2, y: 2, width: fillWidth, height: 5), xRadius: 1.2, yRadius: 1.2)
            (state == .charging ? NSColor.systemGreen : ink).setFill()
            fill.fill()

            if state == .charging {
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: x0 + 10, y: 7.8))
                bolt.line(to: NSPoint(x: x0 + 7.2, y: 4.2))
                bolt.line(to: NSPoint(x: x0 + 9.2, y: 4.2))
                bolt.line(to: NSPoint(x: x0 + 8.2, y: 1.2))
                bolt.line(to: NSPoint(x: x0 + 11, y: 4.9))
                bolt.line(to: NSPoint(x: x0 + 9, y: 4.9))
                bolt.close()
                NSColor.black.setFill()
                bolt.fill()
            }
            return true
        }
        // Template lets macOS tint it for light/dark menu bars; colored states draw their own ink.
        image.isTemplate = state == .normal
        return image
    }
}

extension StatusItemContent.State {
    init(_ s: BatterySnapshot) {
        if s.isCharging { self = .charging }
        else if !s.isPluggedIn, let m = s.minutesToEmpty, m < 30 { self = .low }
        else { self = .normal }
    }
}
