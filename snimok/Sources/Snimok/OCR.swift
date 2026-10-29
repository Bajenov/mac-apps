import Vision

// Распознавание текста встроенными средствами macOS: прямо на Mac, без интернета.
enum OCR {
    static func recognize(_ image: CGImage) async -> String {
        await withCheckedContinuation { done in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { o -> (CGRect, String)? in o.topCandidates(1).first.map { (o.boundingBox, $0.string) } }
                done.resume(returning: join(lines))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { done.resume(returning: "") }
        }
    }

    /// Строки сверху вниз; кусочки одной строки — слева направо через пробел.
    private static func join(_ items: [(CGRect, String)]) -> String {
        let sorted = items.sorted { $0.0.midY > $1.0.midY }
        var rows: [[(CGRect, String)]] = []
        for item in sorted {
            if let last = rows.last?.first, abs(last.0.midY - item.0.midY) < min(last.0.height, item.0.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.0.minX < $1.0.minX }.map(\.1).joined(separator: " ") }.joined(separator: "\n")
    }
}
