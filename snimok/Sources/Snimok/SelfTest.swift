import AppKit

// Самопроверка без разрешения на снимок экрана: Snimok --selftest <папка>
// Рисует выделение с панелью и пометками на тестовой картинке, сохраняет итог и проверяет распознавание текста.
@MainActor
enum SelfTest {
    static func run(_ dir: URL) async {
        let size = CGSize(width: 1000, height: 640)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor(white: 0.93, alpha: 1).setFill(); r.fill()
            NSColor.white.setFill(); NSRect(x: 120, y: 160, width: 620, height: 330).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black]
            NSAttributedString(string: "Привет! Это проверка распознавания.", attributes: attrs).draw(at: CGPoint(x: 150, y: 400))
            NSAttributedString(string: "Телефон +7 999 123-45-67, Москва", attributes: attrs).draw(at: CGPoint(x: 150, y: 340))
            NSAttributedString(string: "Second line in English 2026", attributes: attrs).draw(at: CGPoint(x: 150, y: 280))
            return true
        }
        guard let screen = NSScreen.main, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let shot = DisplayShot(screen: screen, displayID: 0, image: cg, scale: 1)
        let view = OverlayView(shot: shot, windowRects: [], controller: OverlayController.shared, testSize: size)
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -5000, y: -5000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.orderFront(nil)
        let tools = OverlayController.shared.tools
        tools.tool = .arrow
        tools.hint = "Мозаика — скрыть номер или пароль"
        view.testSetup(selection: CGRect(x: 100, y: 140, width: 700, height: 380), annotations: [
            Annotation(tool: .rect, color: Palette.colors[0], width: 4, points: [CGPoint(x: 40, y: 190), CGPoint(x: 560, y: 250)]),
            Annotation(tool: .arrow, color: Palette.colors[1], width: 4, points: [CGPoint(x: 650, y: 40), CGPoint(x: 520, y: 180)]),
            Annotation(tool: .mosaic, color: .black, width: 4, points: [CGPoint(x: 140, y: 195), CGPoint(x: 400, y: 245)]),
            Annotation(tool: .marker, color: Palette.colors[2], width: 4, points: [CGPoint(x: 50, y: 140), CGPoint(x: 300, y: 140), CGPoint(x: 480, y: 142)]),
            Annotation(tool: .number, color: Palette.colors[3], width: 4, points: [CGPoint(x: 30, y: 330)], number: 1),
            Annotation(tool: .text, color: Palette.colors[0], width: 4, points: [CGPoint(x: 80, y: 40)], text: "Подпись на снимке"),
        ])
        try? await Task.sleep(for: .milliseconds(400))
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("overlay.png"))
        }
        if let out = view.export(annotated: true) {
            try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("export.png"))
        }
        if let plain = view.export(annotated: false) {
            let text = await OCR.recognize(plain)
            try? text.write(to: dir.appendingPathComponent("ocr.txt"), atomically: true, encoding: .utf8)
        }
        exit(0)
    }
}
