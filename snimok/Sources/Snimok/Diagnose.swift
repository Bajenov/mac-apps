import AppKit
import ScreenCaptureKit

// Диагностика: Snimok --diagnose <файл>. Пишет, есть ли доступ к экрану и удаётся ли снять экран.
@MainActor
enum Diagnose {
    static func run(_ out: URL) async {
        var lines: [String] = []
        lines.append("preflight: \(CGPreflightScreenCaptureAccess())")
        lines.append("screens: \(NSScreen.screens.map { "\($0.frame) x\($0.backingScaleFactor)" })")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            lines.append("shareable: ok, displays \(content.displays.count), windows \(content.windows.count)")
            let shots = try await ScreenGrab.captureAll()
            lines.append("capture: \(shots.map { "\($0.image.width)x\($0.image.height)" })")
            if let first = shots.first {
                let started = Date()
                let text = await OCR.recognize(first.image)
                lines.append("ocr: \(text.count) знаков за \(String(format: "%.1f", Date().timeIntervalSince(started))) с; начало: \(text.prefix(80).replacingOccurrences(of: "\n", with: " | "))")
            }
        } catch {
            lines.append("error: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
        }
        lines.append("hotkeys busy: \(KeyStatus.shared.busy)")
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        exit(0)
    }
}
