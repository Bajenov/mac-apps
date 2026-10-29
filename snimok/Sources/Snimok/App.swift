import Carbon
import SwiftUI

@main
struct SnimokApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var recorder = Recorder.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            if recorder.isRecording {
                Text("● \(recorder.elapsed)").monospacedDigit()
            } else {
                Image(systemName: "camera.viewfinder")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// У программы без значка в Доке нет меню — без него ⌘C, ⌘V, ⌘A в полях ввода не работают.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            Task { @MainActor in await SelfTest.run(URL(fileURLWithPath: args[i + 1])) }
            return
        }
        installEditMenu()
        let keys = HotKeys.shared
        var busy: [String] = []
        if !keys.register(id: 1, keyCode: kVK_ANSI_A, modifiers: cmdKey | shiftKey, action: { OverlayController.shared.start(.shot) }) { busy.append("⌘⇧A") }
        if !keys.register(id: 2, keyCode: kVK_ANSI_T, modifiers: cmdKey | shiftKey, action: { OverlayController.shared.start(.text) }) { busy.append("⌘⇧T") }
        if !keys.register(id: 3, keyCode: kVK_ANSI_R, modifiers: optionKey | shiftKey, action: {
            if Recorder.shared.isRecording { Recorder.shared.stop() } else { OverlayController.shared.start(.video) }
        }) { busy.append("⌥⇧R") }
        KeyStatus.shared.busy = busy
        if let i = args.firstIndex(of: "--diagnose"), i + 1 < args.count {
            Task { @MainActor in await Diagnose.run(URL(fileURLWithPath: args[i + 1])) }
        }
    }
}
