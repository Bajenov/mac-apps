import AppKit
import ServiceManagement
import SwiftUI

// Окно из строки меню: кнопки, история снимков и распознанных текстов, настройки.

struct MenuView: View {
    @ObservedObject var history = History.shared
    @ObservedObject var recorder = Recorder.shared
    @ObservedObject var keys = KeyStatus.shared
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                big("camera.viewfinder", "Снимок", "⌘⇧A") { run(.shot) }
                big("text.viewfinder", "Текст", "⌘⇧T") { run(.text) }
                if recorder.isRecording {
                    big("stop.circle.fill", "Стоп \(recorder.elapsed)", "⌥⇧R", tint: .red) { recorder.stop() }
                } else {
                    big("record.circle", "Видео", "⌥⇧R") { run(.video) }
                }
            }
            if !keys.busy.isEmpty {
                Text("Сочетания \(keys.busy.joined(separator: ", ")) заняты другой программой (например, iScreen Shoter). Закройте её и перезапустите «Снимок».")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Picker("", selection: $tab) {
                Text("Снимки и видео").tag(0)
                Text("Тексты").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()

            ScrollView {
                if tab == 0 { shots } else { texts }
            }
            .frame(height: 330)

            Divider()
            HStack {
                Toggle("Звук компьютера в видео", isOn: $recorder.systemAudio)
                Spacer()
                Toggle("Микрофон", isOn: $recorder.microphone)
            }
            .toggleStyle(.checkbox).font(.system(size: 12))
            HStack {
                LoginToggle()
                Spacer()
                Button("Папка") { NSWorkspace.shared.open(History.picturesDir) }.buttonStyle(.link)
                Button("Выйти") { NSApp.terminate(nil) }.buttonStyle(.link)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { history.reload() }
    }

    private func run(_ m: CaptureMode) {
        NSApp.keyWindow?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { OverlayController.shared.start(m) }
    }

    private func big(_ icon: String, _ title: String, _ key: String, tint: Color = .accentColor, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(key).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shots: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(history.shots) { item in ShotCell(item: item) }
        }
        .overlay { if history.shots.isEmpty { empty("Здесь появятся снимки и видео") } }
    }

    private var texts: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(history.texts) { t in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t.text, forType: .string)
                    Toast.show("Текст скопирован", String(t.text.prefix(120)))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.text).font(.system(size: 12)).lineLimit(3).multilineTextAlignment(.leading)
                        Text(t.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("Нажмите, чтобы скопировать")
            }
        }
        .overlay { if history.texts.isEmpty { empty("Здесь появятся распознанные тексты") } }
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 60)
    }
}

struct ShotCell: View {
    let item: ShotItem
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if item.isVideo {
                Image(systemName: "play.circle.fill").font(.system(size: 16)).foregroundStyle(.white).shadow(radius: 2).padding(5)
            }
        }
        .frame(height: 72)
        .contentShape(Rectangle())
        .onTapGesture { copy() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Копировать") { copy() }
            Button("Открыть") { NSWorkspace.shared.open(item.url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("В Корзину") { History.shared.trash(item) }
        }
        .help("Щелчок — скопировать, двойной — открыть, правая кнопка — ещё")
        .onAppear { History.shared.thumbnail(item) { image = $0 } }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.isVideo {
            pb.writeObjects([item.url as NSURL])
        } else if let img = NSImage(contentsOf: item.url) {
            pb.writeObjects([img])
        }
        Toast.show(item.isVideo ? "Видео скопировано" : "Снимок скопирован", "Вставьте ⌘V")
    }
}

@MainActor
final class KeyStatus: ObservableObject {
    static let shared = KeyStatus()
    @Published var busy: [String] = []
}

struct LoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle("Запускать при входе", isOn: Binding(get: { on }, set: { v in
            if (try? v ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) != nil { on = v }
        }))
        .toggleStyle(.switch).controlSize(.mini)
    }
}
