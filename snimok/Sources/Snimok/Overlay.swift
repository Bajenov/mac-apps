import AppKit
import Combine
import SwiftUI

// Экран выделения: «замороженный» снимок, затемнение, перекрестие, подсветка окон («Авто»),
// рамка с 8 ручками, пометки и панель инструментов прямо под выделением.

enum CaptureMode { case shot, text, video }

final class ToolState: ObservableObject {
    @Published var tool: Tool?
    @Published var colorIndex = 0
    @Published var widthIndex = 1
    @Published var canUndo = false
    @Published var hint: String?
    var color: NSColor { Palette.colors[colorIndex] }
    var width: CGFloat { Palette.widths[widthIndex] }
}

@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var windows: [OverlayWindow] = []
    private(set) var mode = CaptureMode.shot
    let tools = ToolState()
    var isOpen: Bool { !windows.isEmpty }

    func start(_ mode: CaptureMode) {
        guard !isOpen, !Recorder.shared.isRecording || mode != .video else {
            if Recorder.shared.isRecording, mode == .video { Recorder.shared.stop() }
            return
        }
        self.mode = mode
        tools.tool = nil
        tools.canUndo = false
        tools.hint = nil
        Task {
            do {
                let shots = try await ScreenGrab.captureAll()
                let rects = ScreenGrab.windowRects()
                NSApp.activate(ignoringOtherApps: true)
                windows = shots.map { OverlayWindow(shot: $0, windows: rects, controller: self) }
                windows.forEach { $0.makeKeyAndOrderFront(nil) }
                (windows.first { $0.screen == NSScreen.main } ?? windows.first)?.makeKey()
            } catch {
                let e = error as NSError
                Toast.show(CGPreflightScreenCaptureAccess() ? "Не удалось снять экран" : "Нет разрешения на снимок экрана",
                           "\(e.localizedDescription) (\(e.domain) \(e.code)). Настройки → Конфиденциальность и безопасность → Запись экрана — включите «Снимок» и перезапустите его.",
                           seconds: 10)
            }
        }
    }

    /// Выделение началось на одном мониторе — на остальных снимаем своё.
    func selectionBegan(on view: OverlayView) {
        for w in windows where w.overlay !== view { w.overlay.clearSelection() }
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    // MARK: Действия панели

    func finish(_ action: Action, from view: OverlayView) {
        guard let sel = view.selection, sel.width >= 2, sel.height >= 2 else { close(); return }
        let shot = view.shot
        switch action {
        case .cancel:
            close()
        case .copy, .save:
            guard let image = view.export(annotated: true) else { close(); return }
            close()
            let url = History.newURL(video: false)
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = CGSize(width: CGFloat(image.width) / view.pxScale, height: CGFloat(image.height) / view.pxScale)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(png, forType: .png)
                if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
            History.shared.reload()
            if action == .save {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                Toast.show("Снимок скопирован", "Вставьте ⌘V. Файл — в «Изображения → Снимки».")
            }
        case .pin:
            guard let image = view.export(annotated: true) else { close(); return }
            let origin = CGPoint(x: shot.screen.frame.minX + sel.minX, y: shot.screen.frame.minY + sel.minY)
            close()
            PinWindow.show(image, scale: view.pxScale, at: origin)
        case .text, .textQuick:
            guard let image = view.export(annotated: false) else { close(); return }
            close()
            Task {
                let text = await OCR.recognize(image)
                if text.isEmpty {
                    Toast.show("Текст не найден", "Попробуйте выделить крупнее или ровнее.")
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    History.shared.addText(text)
                    if action == .textQuick {
                        Toast.show("Текст скопирован · \(text.count) знаков", String(text.prefix(140)))
                    } else {
                        TextResultWindow.show(text)
                    }
                }
            }
        case .video:
            // Источник записи — в точках монитора, начало координат сверху слева.
            let h = shot.screen.frame.height
            let rect = CGRect(x: sel.minX, y: h - sel.maxY, width: sel.width, height: sel.height)
            let screenRect = sel.offsetBy(dx: shot.screen.frame.minX, dy: shot.screen.frame.minY)
            close()
            Recorder.shared.start(displayID: shot.displayID, sourceRect: rect, screenRect: screenRect, scale: shot.scale)
        }
    }

    enum Action { case cancel, copy, save, pin, text, textQuick, video }
}

final class OverlayWindow: NSWindow {
    let overlay: OverlayView

    init(shot: DisplayShot, windows: [ScreenGrab.WindowInfo], controller: OverlayController) {
        overlay = OverlayView(shot: shot, windowRects: windows, controller: controller)
        super.init(contentRect: shot.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlay
        setFrame(shot.screen.frame, display: false)
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView, NSTextFieldDelegate {
    let shot: DisplayShot
    private let controller: OverlayController
    private let windowRects: [ScreenGrab.WindowInfo]   // в координатах этого монитора
    private var tools: ToolState { controller.tools }
    private var pixelated: CGImage?

    private(set) var selection: CGRect?
    /// Пикселей снимка на точку экрана — по самой картинке, а не по настройке монитора.
    var pxScale: CGFloat { bounds.width > 0 ? CGFloat(shot.image.width) / bounds.width : shot.scale }
    private var hover: CGRect?
    private var hoverName = ""
    private var mouse: CGPoint?
    private var annotations: [Annotation] = []
    private var drawing: Annotation?
    private var drag = Drag.none
    private var downPoint = CGPoint.zero
    private var textField: NSTextField?
    private var toolbar: NSHostingView<ToolbarView>?
    private var bag: AnyCancellable?

    enum Drag { case none, selecting(CGPoint), moving(CGPoint, CGRect), resizing(Int, CGRect), drawing }

    init(shot: DisplayShot, windowRects: [ScreenGrab.WindowInfo], controller: OverlayController, testSize: CGSize? = nil) {
        self.shot = shot
        self.controller = controller
        let origin = shot.screen.frame.origin
        let bounds = CGRect(origin: .zero, size: testSize ?? shot.screen.frame.size)
        self.windowRects = windowRects.compactMap { w in
            let r = w.rect.offsetBy(dx: -origin.x, dy: -origin.y)
            return r.intersects(bounds) ? ScreenGrab.WindowInfo(rect: r.intersection(bounds), name: w.name) : nil
        }
        super.init(frame: bounds)
        bag = controller.tools.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.layoutToolbar()
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let s = selection, tools.tool == nil, case .none = drag { addCursorRect(s.insetBy(dx: 6, dy: 6), cursor: .openHand) }
    }

    func testSetup(selection s: CGRect, annotations a: [Annotation]) {
        selection = s
        annotations = a
        layoutToolbar()
        needsDisplay = true
    }

    func clearSelection() {
        selection = nil
        annotations = []
        toolbar?.removeFromSuperview()
        toolbar = nil
        needsDisplay = true
    }

    // MARK: Рисование

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(shot.image, in: bounds)
        let bright = selection ?? hover
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addRect(bounds)
        if let b = bright { ctx.addRect(b) }
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if let s = selection {
            ctx.saveGState()
            ctx.translateBy(x: s.minX, y: s.minY)
            ctx.clip(to: CGRect(origin: .zero, size: s.size))
            for a in annotations + (drawing.map { [$0] } ?? []) {
                Renderer.draw(a, in: ctx) { r in self.drawMosaic(r.offsetBy(dx: s.minX, dy: s.minY), ctx: ctx, shift: s.origin) }
            }
            ctx.restoreGState()
            ctx.setStrokeColor(Palette.brand.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(s)
            if tools.tool == nil {
                ctx.setFillColor(NSColor.white.cgColor)
                for h in handles(of: s) {
                    let r = CGRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)
                    ctx.fillEllipse(in: r)
                    ctx.strokeEllipse(in: r)
                }
            }
            label("\(Int(s.width * pxScale)) × \(Int(s.height * pxScale))",
                  at: CGPoint(x: s.minX, y: min(s.maxY + 6, bounds.maxY - 22)))
            if let hint = tools.hint, let bar = toolbar, !bar.isHidden {
                // Подсказка к кнопке под курсором — над панелью, а если сверху мало места — под ней.
                let w = NSAttributedString(string: hint, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).size().width + 12
                let x = min(max(4, bar.frame.maxX - w), bounds.maxX - w - 4)
                let above = bar.frame.maxY + 6
                label(hint, at: CGPoint(x: x, y: above + 24 < bounds.maxY ? above : bar.frame.minY - 28), fill: Palette.brand)
            }
        } else {
            if let h = hover {
                ctx.setStrokeColor(Palette.brand.cgColor)
                ctx.setLineWidth(3)
                ctx.stroke(h.insetBy(dx: 1.5, dy: 1.5))
                if !hoverName.isEmpty {
                    let name = hoverName.count > 70 ? String(hoverName.prefix(70)) + "…" : hoverName
                    label("\(name) · щёлкните, чтобы снять окно", at: CGPoint(x: h.minX + 8, y: max(h.maxY - 30, 8)))
                }
            }
            if let m = mouse {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.move(to: CGPoint(x: 0, y: m.y)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: m.y))
                ctx.move(to: CGPoint(x: m.x, y: 0)); ctx.addLine(to: CGPoint(x: m.x, y: bounds.maxY))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                let hint: String
                switch controller.mode {
                case .shot: hint = "Тяните рамку или щёлкните по окну · Esc — отмена"
                case .text: hint = "Выделите текст · ⌘C — скопировать сразу · Enter — с правкой · Esc — отмена"
                case .video: hint = "Выделите область для записи видео · Esc — отмена"
                }
                label(hint, at: CGPoint(x: min(m.x + 14, bounds.maxX - 330), y: max(m.y - 28, 8)))
            }
        }
    }

    private func drawMosaic(_ r: CGRect, ctx: CGContext, shift: CGPoint) {
        if pixelated == nil { pixelated = Renderer.pixelate(shot.image, scale: pxScale) }
        guard let p = pixelated else { return }
        ctx.saveGState()
        ctx.translateBy(x: -shift.x, y: -shift.y)
        ctx.clip(to: r)
        ctx.draw(p, in: bounds)
        ctx.restoreGState()
    }

    private func label(_ text: String, at p: CGPoint, fill: NSColor = NSColor.black.withAlphaComponent(0.7)) {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                              .foregroundColor: NSColor.white])
        let size = s.size()
        let box = CGRect(x: p.x, y: p.y, width: size.width + 12, height: size.height + 6)
        fill.setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        s.draw(at: CGPoint(x: p.x + 6, y: p.y + 3))
    }

    private func handles(of s: CGRect) -> [CGPoint] {
        [CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.midX, y: s.minY), CGPoint(x: s.maxX, y: s.minY),
         CGPoint(x: s.maxX, y: s.midY), CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.midX, y: s.maxY),
         CGPoint(x: s.minX, y: s.maxY), CGPoint(x: s.minX, y: s.midY)]
    }

    // MARK: Мышь

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p
        if selection == nil {
            let w = windowRects.first { $0.rect.contains(p) }
            hover = w?.rect
            hoverName = w?.name ?? ""
        }
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        commitText()
        let p = convert(e.locationInWindow, from: nil)
        downPoint = p
        if let s = selection {
            if e.clickCount == 2, s.contains(p), tools.tool == nil {
                controller.finish(primaryAction, from: self)
                return
            }
            if let tool = tools.tool, s.insetBy(dx: -2, dy: -2).contains(p) {
                startDrawing(tool, at: CGPoint(x: p.x - s.minX, y: p.y - s.minY))
                return
            }
            if tools.tool == nil {
                if let i = handles(of: s).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 8 }) {
                    drag = .resizing(i, s); hideToolbar(); return
                }
                if s.contains(p) { drag = .moving(p, s); hideToolbar(); NSCursor.closedHand.set(); return }
            }
            if tools.tool != nil { return }
        }
        controller.selectionBegan(on: self)
        clearSelection()
        drag = .selecting(p)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        mouse = p
        switch drag {
        case .selecting(let a):
            if hypot(p.x - a.x, p.y - a.y) > 3 {
                hover = nil
                selection = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
                    .intersection(bounds)
            }
        case .moving(let start, let orig):
            var r = orig.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(0, r.minX), bounds.maxX - r.width)
            r.origin.y = min(max(0, r.minY), bounds.maxY - r.height)
            selection = r
        case .resizing(let i, let o):
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            if [0, 6, 7].contains(i) { minX = p.x }
            if [2, 3, 4].contains(i) { maxX = p.x }
            if [0, 1, 2].contains(i) { minY = p.y }
            if [4, 5, 6].contains(i) { maxY = p.y }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
                .intersection(bounds)
        case .drawing:
            guard let s = selection, var d = drawing else { break }
            let q = CGPoint(x: min(max(p.x - s.minX, 0), s.width), y: min(max(p.y - s.minY, 0), s.height))
            if d.tool == .marker { d.points.append(q) } else { d.points = [d.points[0], q] }
            drawing = d
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        // Сначала «отпускаем» мышь: панель показывается, только когда ничего не тянется.
        let finished = drag
        drag = .none
        switch finished {
        case .selecting:
            if selection == nil {
                // Просто щелчок — берём окно под мышью, а если окна нет — весь экран.
                selection = windowRects.first { $0.rect.contains(p) }?.rect ?? bounds
            }
            hover = nil
            selectionDone()
        case .moving, .resizing:
            selectionDone()
        case .drawing:
            if let d = drawing, d.tool == .marker || d.rect.width > 2 || d.rect.height > 2 || d.tool == .number {
                annotations.append(d)
                tools.canUndo = true
            }
            drawing = nil
        case .none:
            break
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) { controller.finish(.cancel, from: self) }

    private func selectionDone() {
        guard let s = selection, s.width >= 4, s.height >= 4 else { clearSelection(); return }
        layoutToolbar()
    }

    private func startDrawing(_ tool: Tool, at q: CGPoint) {
        switch tool {
        case .text:
            beginText(at: q)
        case .number:
            let n = annotations.filter { $0.tool == .number }.count + 1
            annotations.append(Annotation(tool: .number, color: tools.color, width: tools.width, points: [q], number: n))
            tools.canUndo = true
            needsDisplay = true
        default:
            drawing = Annotation(tool: tool, color: tools.color, width: tools.width, points: [q, q])
            drag = .drawing
        }
    }

    // MARK: Текст

    private func beginText(at q: CGPoint) {
        guard let s = selection else { return }
        let font = Annotation.font(for: tools.width)
        let h = ceil(font.ascender - font.descender) + 6
        let f = NSTextField(frame: CGRect(x: s.minX + q.x - 2, y: s.minY + q.y - h / 2, width: max(120, s.maxX - (s.minX + q.x)), height: h))
        f.font = font
        f.textColor = tools.color
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.placeholderString = "Текст"
        f.delegate = self
        f.target = self
        f.action = #selector(textEntered)
        addSubview(f)
        window?.makeFirstResponder(f)
        textField = f
    }

    @objc private func textEntered() { commitText() }

    private func commitText() {
        guard let f = textField, let s = selection else { return }
        textField = nil
        let text = f.stringValue
        let origin = CGPoint(x: f.frame.minX - s.minX + 2, y: f.frame.minY - s.minY + 3)
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }
        annotations.append(Annotation(tool: .text, color: f.textColor ?? tools.color, width: tools.width, points: [origin], text: text))
        tools.canUndo = true
        needsDisplay = true
    }

    // MARK: Клавиши

    /// ⌘C, ⌘S, ⌘Z ловим первыми — раньше меню «Правка» и панели кнопок, которые иначе их перехватывают.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              textField == nil else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "c", "с":
            guard selection != nil else { return true }
            controller.finish(controller.mode == .text ? .textQuick : .copy, from: self)
            return true
        case "s", "ы":
            if selection != nil { controller.finish(.save, from: self) }
            return true
        case "z", "я":
            undo()
            return true
        default:
            return super.performKeyEquivalent(with: e)
        }
    }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 53: controller.finish(.cancel, from: self)                                   // Esc
        case 36, 76: if selection != nil { controller.finish(primaryAction, from: self) }
        default:
            if cmd, e.charactersIgnoringModifiers == "z" { undo() }
            else if cmd, e.charactersIgnoringModifiers == "c" {
                if selection != nil { controller.finish(controller.mode == .text ? .textQuick : .copy, from: self) }
            }
            else if cmd, e.charactersIgnoringModifiers == "s" { controller.finish(.save, from: self) }
            else { super.keyDown(with: e) }
        }
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { commitText(); return true }
        return false
    }

    /// ⌘C через меню «Правка»: в режиме текста — распознать и сразу скопировать, иначе — скопировать снимок.
    @objc func copy(_ sender: Any?) {
        guard selection != nil else { return }
        controller.finish(controller.mode == .text ? .textQuick : .copy, from: self)
    }

    /// Что делают Enter и двойной щелчок в каждом режиме.
    private var primaryAction: OverlayController.Action {
        switch controller.mode { case .shot: .copy; case .text: .text; case .video: .video }
    }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        tools.canUndo = !annotations.isEmpty
        needsDisplay = true
    }

    // MARK: Панель

    private func hideToolbar() { toolbar?.isHidden = true }

    func layoutToolbar() {
        guard let s = selection, case .none = drag else { return }
        let view = ToolbarView(state: tools, mode: controller.mode, act: { [weak self] a in self?.toolbarAction(a) })
        let host = toolbar ?? NSHostingView(rootView: view)
        host.rootView = view
        host.isHidden = false
        let size = host.fittingSize
        var y = s.minY - size.height - 8
        if y < 4 { y = s.maxY + 8 }
        if y + size.height > bounds.maxY - 4 { y = s.minY + 8 }
        let x = min(max(4, s.maxX - size.width), bounds.maxX - size.width - 4)
        host.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        if toolbar == nil { addSubview(host); toolbar = host }
    }

    private func toolbarAction(_ a: ToolbarView.Tap) {
        switch a {
        case .undo: undo()
        case .action(let act): controller.finish(act, from: self)
        }
        window?.makeFirstResponder(self)
    }

    // MARK: Итоговая картинка

    func export(annotated: Bool) -> CGImage? {
        guard let s = selection else { return nil }
        commitText()
        let k = pxScale
        let px = CGRect(x: s.minX * k, y: (bounds.height - s.maxY) * k, width: s.width * k, height: s.height * k).integral
        guard let crop = shot.image.cropping(to: px) else { return nil }
        guard annotated, !annotations.isEmpty else { return crop }
        guard let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return crop }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        ctx.scaleBy(x: CGFloat(crop.width) / s.width, y: CGFloat(crop.height) / s.height)
        let local = CGRect(origin: .zero, size: s.size)
        if pixelated == nil, annotations.contains(where: { $0.tool == .mosaic }) { pixelated = Renderer.pixelate(shot.image, scale: k) }
        let mosaicCrop = pixelated?.cropping(to: px)
        for a in annotations {
            Renderer.draw(a, in: ctx) { r in
                guard let m = mosaicCrop else { return }
                ctx.saveGState(); ctx.clip(to: r); ctx.draw(m, in: local); ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }
}

// MARK: - Панель инструментов

struct ToolbarView: View {
    @ObservedObject var state: ToolState
    let mode: CaptureMode
    let act: (Tap) -> Void

    enum Tap { case undo, action(OverlayController.Action) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 2) {
                btn("xmark", "Отмена (Esc)") { act(.action(.cancel)) }
                if mode == .text {
                    Divider().frame(height: 22)
                    Button { act(.action(.text)) } label: {
                        Label("Распознать текст", systemImage: "text.viewfinder").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Palette.brand)))
                    }
                    .buttonStyle(.plain)
                    .onHover { state.hint = $0 ? "Enter или двойной щелчок — окно с правкой · ⌘C — скопировать сразу" : nil }
                } else if mode == .video {
                    Divider().frame(height: 22)
                    Button { act(.action(.video)) } label: {
                        Label("Начать запись", systemImage: "record.circle").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.red))
                    }.buttonStyle(.plain)
                    .onHover { state.hint = $0 ? "Красная рамка покажет, что пишется · стоп — ⌥⇧R" : nil }
                } else {
                    Divider().frame(height: 22).padding(.horizontal, 2)
                    tool(.rect, "rectangle", "Рамка")
                    tool(.ellipse, "circle", "Овал")
                    tool(.line, "line.diagonal", "Линия")
                    tool(.arrow, "arrow.up.right", "Стрелка")
                    tool(.marker, "highlighter", "Маркер")
                    tool(.mosaic, "checkerboard.rectangle", "Мозаика — скрыть номер или пароль")
                    tool(.text, "textformat", "Текст")
                    tool(.number, "1.circle", "Номера 1, 2, 3…")
                    btn("arrow.uturn.backward", "Отменить (⌘Z)") { act(.undo) }.disabled(!state.canUndo).opacity(state.canUndo ? 1 : 0.35)
                    Divider().frame(height: 22).padding(.horizontal, 2)
                    btn("text.viewfinder", "Распознать текст и скопировать") { act(.action(.text)) }
                    btn("record.circle", "Записать видео этой области") { act(.action(.video)) }
                    btn("pin", "Закрепить поверх окон") { act(.action(.pin)) }
                    btn("square.and.arrow.down", "Сохранить и показать в Finder (⌘S)") { act(.action(.save)) }
                    Button { act(.action(.copy)) } label: {
                        Text("OK").font(.system(size: 14, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Palette.brand)))
                    }
                    .buttonStyle(.plain)
                    .onHover { state.hint = $0 ? "Скопировать и сохранить · Enter, ⌘C или двойной щелчок" : nil }
                }
            }
            if state.tool != nil {
                HStack(spacing: 8) {
                    ForEach(Palette.colors.indices, id: \.self) { i in
                        Circle().fill(Color(nsColor: Palette.colors[i])).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white, lineWidth: state.colorIndex == i ? 2 : 0.5))
                            .onTapGesture { state.colorIndex = i }
                    }
                    Divider().frame(height: 16)
                    ForEach(Palette.widths.indices, id: \.self) { i in
                        Circle().fill(Color.white).frame(width: 4 + Palette.widths[i] * 1.3, height: 4 + Palette.widths[i] * 1.3)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(state.widthIndex == i ? 0.2 : 0)))
                            .onTapGesture { state.widthIndex = i }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13).opacity(0.96)))
            }
        }
        .padding(0)
        .background(alignment: .top) { EmptyView() }
        .modifier(Bar(show: true))
        .environment(\.colorScheme, .dark)
    }

    private func tool(_ t: Tool, _ icon: String, _ hint: String) -> some View {
        btn(icon, hint, on: state.tool == t) { state.tool = state.tool == t ? nil : t }
    }

    private func btn(_ icon: String, _ hint: String, on: Bool = false, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color(nsColor: Palette.brand) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onHover { inside in
            if inside { state.hint = hint } else if state.hint == hint { state.hint = nil }
        }
    }

    private struct Bar: ViewModifier {
        let show: Bool
        func body(content: Content) -> some View {
            content.padding(6).background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.1).opacity(0.96)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
        }
    }
}
