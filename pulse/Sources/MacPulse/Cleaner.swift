import AppKit
import Foundation

// Очистка: только то, что программы сами создадут заново. Ничего не стирается насовсем — всё уходит в Корзину.

struct CleanItem: Identifiable {
    let id: URL
    let name: String
    let bytes: Int64
    var selected: Bool
    var note: String? = nil
}

struct CleanGroup: Identifiable {
    let id: String
    let title: String
    let hint: String
    var items: [CleanItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var selectedBytes: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.bytes } }
}

@MainActor
final class Cleaner: ObservableObject {
    enum Phase { case idle, scanning, ready, cleaning, done }

    @Published var groups: [CleanGroup] = []
    @Published private(set) var phase = Phase.idle
    @Published private(set) var movedBytes: Int64 = 0
    @Published private(set) var failures: [String] = []

    var selectedBytes: Int64 { groups.reduce(0) { $0 + $1.selectedBytes } }

    func scan() {
        phase = .scanning
        failures = []
        Task.detached(priority: .userInitiated) {
            let found = Self.findAll()
            await MainActor.run {
                self.groups = found
                self.phase = .ready
            }
        }
    }

    func moveSelectedToTrash() {
        let targets = groups.flatMap(\.items).filter(\.selected)
        guard !targets.isEmpty else { return }
        phase = .cleaning
        Task.detached(priority: .userInitiated) {
            var moved: Int64 = 0
            var failed: [String] = []
            for item in targets {
                do {
                    try FileManager.default.trashItem(at: item.id, resultingItemURL: nil)
                    moved += item.bytes
                } catch {
                    failed.append(item.name)
                }
            }
            await MainActor.run {
                self.movedBytes = moved
                self.failures = failed
                self.phase = .done
                self.groups = []
            }
        }
    }

    func toggle(group: String, item: URL) {
        guard let g = groups.firstIndex(where: { $0.id == group }),
              let i = groups[g].items.firstIndex(where: { $0.id == item }) else { return }
        groups[g].items[i].selected.toggle()
    }

    func setAll(group: String, _ on: Bool) {
        guard let g = groups.firstIndex(where: { $0.id == group }) else { return }
        // Пункты с предупреждением (открытая программа, обновление) общей галочкой не включаем.
        for i in groups[g].items.indices where !on || groups[g].items[i].note == nil { groups[g].items[i].selected = on }
    }

    // MARK: - Поиск

    nonisolated private static let home = FileManager.default.homeDirectoryForCurrentUser
    nonisolated private static let minBytes: Int64 = 1_000_000

    nonisolated private static func findAll() -> [CleanGroup] {
        var out: [CleanGroup] = []
        let caches = children(of: home.appendingPathComponent("Library/Caches"))
            .filter { !isApple($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix("local.pulse") }
        let running = runningApps()
        let cacheItems = items(caches, selected: true).map { item -> CleanItem in
            var it = item
            let n = item.id.lastPathComponent.lowercased()
            if let app = running.first(where: { n == $0.id || ($0.name.count > 2 && $0.name.hasPrefix(n)) || n.hasPrefix($0.name) }) {
                it.selected = false
                it.note = "\(app.display) сейчас открыт — сначала закройте"
            } else if n.contains("playwright") {
                it.selected = false
                it.note = "браузеры для автотестов — потом долго скачиваются заново"
            } else if n.contains("shipit") || n.contains("updater") || n.contains("update") {
                it.selected = false
                it.note = "скачанное обновление — может ставиться прямо сейчас"
            }
            return it
        }
        out.append(CleanGroup(id: "caches", title: "Кэши программ",
                              hint: "Временные файлы браузеров и программ. Создадутся заново, первый запуск может быть чуть медленнее.",
                              items: cacheItems))
        out.append(CleanGroup(id: "logs", title: "Журналы программ",
                              hint: "Старые записи о работе программ. Нужны только для разбора сбоев.",
                              items: items(children(of: home.appendingPathComponent("Library/Logs")), selected: true)))
        let dev = ["Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches",
                   ".npm/_cacache", ".cache/pip", ".gradle/caches"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        out.append(CleanGroup(id: "dev", title: "Для разработчиков",
                              hint: "Промежуточные файлы сборки и скачанные пакеты. Скачаются заново при следующей сборке.",
                              items: items(dev, selected: true)))
        return out.filter { !$0.items.isEmpty }
    }

    nonisolated private static func items(_ urls: [URL], selected: Bool) -> [CleanItem] {
        urls.map { CleanItem(id: $0, name: displayName($0), bytes: size(of: $0), selected: selected) }
            .filter { $0.bytes >= minBytes }
            .sorted { $0.bytes > $1.bytes }
    }

    nonisolated private static func children(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
    }

    /// Системные кэши Apple не трогаем: без них macOS может вести себя странно.
    nonisolated private static func isApple(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || ["CloudKit", "FamilyCircle", "GeoServices", "SiriTTS", "familycircled",
                                          "storeassetd", "PassKit", "icloudmailagent", "askpermissiond"].contains(name)
    }

    /// Открытые сейчас программы: идентификатор, имя в нижнем регистре и как показать.
    nonisolated private static func runningApps() -> [(id: String, name: String, display: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let name = app.localizedName else { return nil }
            return ((app.bundleIdentifier ?? "").lowercased(), name.lowercased(), name)
        }
    }

    nonisolated private static func displayName(_ url: URL) -> String {
        let n = url.lastPathComponent
        let path = url.path.replacingOccurrences(of: home.path, with: "~")
        if url.pathComponents.contains("Caches") || url.pathComponents.contains("Logs") {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: n) {
                return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            }
            return n
        }
        return path
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

func bytesText(_ b: Int64) -> String {
    let mb = Double(b) / 1_000_000
    return mb >= 1000 ? rf("%.1f ГБ", mb / 1000) : rf("%.0f МБ", mb)
}
