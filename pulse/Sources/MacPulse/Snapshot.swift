import AppKit
import SwiftUI

// Служебный режим для проверки вида: MacPulse --snapshot out.png [вкладка 0|1|2]
// Рисует окно программы в картинку и выходит. Разрешение на запись экрана не нужно.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let tab = i + 2 < args.count ? Int(args[i + 2]) ?? 0 : 0
        Task { @MainActor in
            let monitor = Monitor()
            let cleaner = Cleaner()
            if tab == 2 { cleaner.scan() }
            let view = PanelView(initialTab: tab, cleaner: cleaner).environmentObject(monitor)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 640)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            w.orderFront(nil)
            window = w
            try? await Task.sleep(for: .seconds(tab == 2 ? 12 : 5))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
            }
            exit(0)
        }
    }
}
