import AppKit
import CoreImage

// Пометки на снимке и их рисование. Один и тот же код рисует и на экране, и в итоговую картинку.

enum Tool: String, CaseIterable {
    case rect, ellipse, line, arrow, marker, mosaic, text, number
}

enum Palette {
    static let brand = NSColor(red: 0.106, green: 0.369, blue: 0.894, alpha: 1)
    static let colors: [NSColor] = [
        NSColor(red: 0.96, green: 0.26, blue: 0.26, alpha: 1),
        NSColor(red: 1.00, green: 0.78, blue: 0.10, alpha: 1),
        NSColor(red: 0.20, green: 0.80, blue: 0.40, alpha: 1),
        NSColor(red: 0.20, green: 0.50, blue: 1.00, alpha: 1),
        .white,
        .black,
    ]
    static let widths: [CGFloat] = [2, 4, 7]
}

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]        // в координатах выделения (0,0 — левый нижний угол)
    var text = ""
    var number = 0

    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func font(for width: CGFloat) -> NSFont { .systemFont(ofSize: 12 + width * 3, weight: .bold) }
}

enum Renderer {
    /// mosaic — нарисовать «мозаику» в прямоугольнике (координаты выделения).
    static func draw(_ a: Annotation, in ctx: CGContext, mosaic: (CGRect) -> Void) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.tool {
        case .rect:
            ctx.stroke(a.rect)
        case .ellipse:
            ctx.strokeEllipse(in: a.rect)
        case .line:
            guard let p = a.points.first, let q = a.points.last else { return }
            ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath()
        case .arrow:
            guard let p = a.points.first, let q = a.points.last, p != q else { return }
            let angle = atan2(q.y - p.y, q.x - p.x)
            let head = max(12, a.width * 4)
            let back = CGPoint(x: q.x - cos(angle) * head * 0.8, y: q.y - sin(angle) * head * 0.8)
            ctx.move(to: p); ctx.addLine(to: back); ctx.strokePath()
            ctx.move(to: q)
            ctx.addLine(to: CGPoint(x: q.x - cos(angle - 0.45) * head, y: q.y - sin(angle - 0.45) * head))
            ctx.addLine(to: CGPoint(x: q.x - cos(angle + 0.45) * head, y: q.y - sin(angle + 0.45) * head))
            ctx.closePath(); ctx.fillPath()
        case .marker:
            guard let first = a.points.first else { return }
            ctx.setStrokeColor(a.color.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(a.width * 5)
            ctx.setLineCap(.butt)
            ctx.move(to: first)
            for p in a.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .mosaic:
            mosaic(a.rect)
        case .text:
            guard let p = a.points.first, !a.text.isEmpty else { return }
            withNS(ctx) {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(a.color == .black ? 0 : 0.55)
                shadow.shadowBlurRadius = 3
                NSAttributedString(string: a.text, attributes: [.font: Annotation.font(for: a.width),
                                                                .foregroundColor: a.color, .shadow: shadow]).draw(at: p)
            }
        case .number:
            guard let c = a.points.first else { return }
            let r = 10 + a.width * 2
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            withNS(ctx) {
                let s = NSAttributedString(string: "\(a.number)", attributes: [
                    .font: NSFont.systemFont(ofSize: r * 1.1, weight: .heavy),
                    .foregroundColor: a.color == .white || a.color.brightness > 0.8 ? NSColor.black : NSColor.white])
                let size = s.size()
                s.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
            }
        }
    }

    private static func withNS(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// «Мозаика» всего снимка: крупные квадраты, чтобы нельзя было прочитать номер или пароль.
    static func pixelate(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIPixellate") else { return nil }
        f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(max(8, 10 * scale), forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let out = f.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }
}

extension NSColor {
    var brightness: CGFloat { usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0 }
}
