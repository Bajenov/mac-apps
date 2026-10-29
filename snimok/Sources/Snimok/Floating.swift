import AppKit
import SwiftUI

// Всплывающая подсказка («Скопировано») и снимок, закреплённый поверх всех окон.

@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ title: String, _ detail: String? = nil, seconds: Double = 2.5) {
        let view = VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.1).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let p = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.contentView = host
        let screen = NSScreen.main?.visibleFrame ?? .zero
        p.setFrame(CGRect(x: screen.maxX - host.frame.width - 16, y: screen.maxY - host.frame.height - 12,
                          width: host.frame.width, height: host.frame.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        hideWork?.cancel()
        let work = DispatchWorkItem { p.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Снимок поверх всех окон: двигается мышью, двойной щелчок или Esc — закрыть.
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []

    static func show(_ image: CGImage, scale: CGFloat, at origin: CGPoint) {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let w = PinWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        w.level = .floating
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces]
        let view = NSImageView(frame: CGRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.borderColor = Palette.brand.cgColor
        view.layer?.borderWidth = 1
        w.contentView = view
        w.orderFrontRegardless()
        open.append(w)
    }

    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { closePin() } else { super.mouseDown(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }
    private func closePin() {
        orderOut(nil)
        Self.open.removeAll { $0 === self }
    }
}

/// Окно с распознанным текстом: можно поправить и скопировать заново. Текст уже в буфере.
@MainActor
enum TextResultWindow {
    private static var window: NSPanel?

    static func show(_ text: String) {
        window?.close()
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 460, height: 320),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Распознанный текст — уже в буфере"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: TextResultView(text: text) { p.close() })
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        window = p
    }
}

struct TextResultView: View {
    @State var text: String
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            HStack {
                Text("\(text.count) знаков · можно поправить").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть", action: close).keyboardShortcut(.cancelAction)
                Button(copied ? "Скопировано ✓" : "Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(minWidth: 380, minHeight: 240)
    }
}
