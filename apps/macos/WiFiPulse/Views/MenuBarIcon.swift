import AppKit

/// メニューバーのアイコン。OS の Wi-Fi のアイコンと見分けられるよう、扇の根元を脈拍の線にしてある。
/// テンプレート画像なので、メニューバーの明暗に合わせて OS が色を付ける。状態は形で表す:
/// 電波の強さは扇の濃さ、未接続は斜線、悪いときは右上の「!」。
enum MenuBarIcon {
    static let size = NSSize(width: 22, height: 16)

    /// 状態は数通りしかないので、作った画像を使い回す（メニューバーは状態が変わったときしか描き直さない）
    private static var cache: [MenuState: NSImage] = [:]

    static func image(for state: MenuState) -> NSImage {
        if let image = cache[state] { return image }
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Wi-Fi Pulse"
        cache[state] = image
        return image
    }

    /// 電波の強さ（0〜4本）→ 濃く描く弧の数（0〜3）
    static func litArcs(bars: Int) -> Int { [0, 1, 1, 2, 3][max(0, min(4, bars))] }

    private static func draw(_ state: MenuState) {
        let center = NSPoint(x: 9, y: 3)
        let lit = state.connected ? litArcs(bars: state.bars) : 0

        // 扇（内側から3本）
        for (i, radius) in [5.0, 8.5, 12.0].enumerated() {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 45, endAngle: 135)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.withAlphaComponent(i < lit ? 1 : 0.3).setStroke()
            arc.stroke()
        }

        // 根元の脈拍
        let pulse = NSBezierPath()
        pulse.move(to: NSPoint(x: 1, y: 2))
        pulse.line(to: NSPoint(x: 5.5, y: 2))
        pulse.line(to: NSPoint(x: 7.5, y: 0.5))
        pulse.line(to: NSPoint(x: 10, y: 6))
        pulse.line(to: NSPoint(x: 12, y: 2))
        pulse.line(to: NSPoint(x: 17, y: 2))
        pulse.lineWidth = 1.6
        pulse.lineCapStyle = .round
        pulse.lineJoinStyle = .round
        NSColor.black.setStroke()
        pulse.stroke()

        if !state.connected {
            // 斜線。周りを透明に抜いてから引き、扇と重なっても読めるようにする
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 2.5, y: 14.5))
            slash.line(to: NSPoint(x: 15.5, y: 1.5))
            slash.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            slash.lineWidth = 4
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            slash.lineWidth = 1.8
            NSColor.black.setStroke()
            slash.stroke()
        } else if state.level == .crit {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 19, y: 6.5, width: 2.2, height: 8.5), xRadius: 1.1, yRadius: 1.1).fill()
            NSBezierPath(ovalIn: NSRect(x: 19, y: 1.5, width: 2.2, height: 2.2)).fill()
        }
    }
}
