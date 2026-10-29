import AppKit
import ScreenCaptureKit

// «Замораживаем» экран: снимаем каждый монитор целиком до того, как появится выделение.

struct DisplayShot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    let scale: CGFloat
}

enum ScreenGrab {
    static func captureAll() async throws -> [DisplayShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [DisplayShot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(DisplayShot(screen: screen, displayID: id, image: image, scale: scale))
        }
        return shots
    }

    /// Окна на экране для «Авто»: наведёшь — подсветится окно. Координаты Cocoa (начало — левый нижний угол главного экрана).
    struct WindowInfo { let rect: CGRect; let name: String }

    static func windowRects() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) ?? 1 == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 40, height > 40 else { return nil }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let title = w[kCGWindowName as String] as? String ?? ""
            let name = title.isEmpty || title == owner ? owner : "\(owner) — \(title)"
            return WindowInfo(rect: CGRect(x: x, y: mainHeight - y - height, width: width, height: height), name: name)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}
