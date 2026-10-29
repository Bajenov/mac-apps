import AppKit
import QuickLookThumbnailing

// История: снимки и видео — файлы в «Изображения/Снимки» и «Фильмы/Снимки», тексты — в texts.json.

struct ShotItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    var isVideo: Bool { url.pathExtension.lowercased() == "mov" }
}

struct TextItem: Codable, Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let text: String
}

@MainActor
final class History: ObservableObject {
    static let shared = History()

    @Published private(set) var shots: [ShotItem] = []
    @Published private(set) var texts: [TextItem] = []

    static let picturesDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Снимки")
    static let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Снимки")
    private static let textsFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snimok/texts.json")

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        var all: [ShotItem] = []
        for dir in [Self.picturesDir, Self.moviesDir] {
            let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
            for u in urls where ["png", "mov"].contains(u.pathExtension.lowercased()) {
                let d = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                all.append(ShotItem(url: u, date: d))
            }
        }
        shots = Array(all.sorted { $0.date > $1.date }.prefix(60))
        if let data = try? Data(contentsOf: Self.textsFile),
           let list = try? JSONDecoder.iso.decode([TextItem].self, from: data) { texts = list }
    }

    func addText(_ text: String) {
        texts.insert(TextItem(date: Date(), text: text), at: 0)
        texts = Array(texts.prefix(50))
        try? FileManager.default.createDirectory(at: Self.textsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.iso.encode(texts).write(to: Self.textsFile, options: .atomic)
    }

    static func newURL(video: Bool) -> URL {
        let dir = video ? moviesDir : picturesDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return dir.appendingPathComponent("\(video ? "Запись" : "Снимок") \(f.string(from: Date())).\(video ? "mov" : "png")")
    }

    func trash(_ item: ShotItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        reload()
    }

    private var thumbCache: [URL: NSImage] = [:]
    func thumbnail(_ item: ShotItem, done: @escaping (NSImage) -> Void) {
        if let t = thumbCache[item.url] { done(t); return }
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 220, height: 140), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                self.thumbCache[item.url] = img
                done(img)
            }
        }
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
