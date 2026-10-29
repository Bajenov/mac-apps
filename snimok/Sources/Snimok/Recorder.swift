import AppKit
import ScreenCaptureKit

// Запись видео выделенной области. Красная рамка показывает, что пишется; сама рамка и окна «Снимка» в видео не попадают.

@MainActor
final class Recorder: NSObject, ObservableObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let shared = Recorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed = "0:00"

    @Published var systemAudio = UserDefaults.standard.object(forKey: "systemAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(systemAudio, forKey: "systemAudio") }
    }
    @Published var microphone = UserDefaults.standard.bool(forKey: "microphone") {
        didSet { UserDefaults.standard.set(microphone, forKey: "microphone") }
    }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var url: URL?
    private var frame: NSWindow?
    private var timer: Timer?
    private var startedAt = Date()

    func start(displayID: CGDirectDisplayID, sourceRect: CGRect, screenRect: CGRect, scale: CGFloat) {
        guard !isRecording else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let c = SCStreamConfiguration()
                c.sourceRect = sourceRect
                c.width = Int(sourceRect.width * scale) / 2 * 2
                c.height = Int(sourceRect.height * scale) / 2 * 2
                c.showsCursor = true
                c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                c.queueDepth = 6
                c.capturesAudio = systemAudio
                c.captureMicrophone = microphone

                let url = History.newURL(video: true)
                let oc = SCRecordingOutputConfiguration()
                oc.outputURL = url
                oc.outputFileType = .mov
                oc.videoCodecType = .h264
                let out = SCRecordingOutput(configuration: oc, delegate: self)
                let s = SCStream(filter: filter, configuration: c, delegate: self)
                try s.addRecordingOutput(out)
                try await s.startCapture()
                stream = s; output = out; self.url = url
                isRecording = true
                startedAt = Date()
                elapsed = "0:00"
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let t = Int(Date().timeIntervalSince(self.startedAt))
                        self.elapsed = "\(t / 60):" + String(format: "%02d", t % 60)
                    }
                }
                showFrame(screenRect)
                Toast.show("Идёт запись", "Остановить — ⌥⇧R или значок в строке меню.")
            } catch {
                Toast.show("Не удалось начать запись", error.localizedDescription, seconds: 6)
            }
        }
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
        timer?.invalidate()
        frame?.orderOut(nil)
        frame = nil
        isRecording = false
    }

    private func showFrame(_ r: CGRect) {
        let w = NSWindow(contentRect: r.insetBy(dx: -3, dy: -3), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let v = NSView(frame: CGRect(origin: .zero, size: w.frame.size))
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemRed.cgColor
        v.layer?.borderWidth = 2
        w.contentView = v
        w.orderFrontRegardless()
        frame = w
    }

    nonisolated func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) {
        Task { @MainActor in
            guard let url = self.url else { return }
            History.shared.reload()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            Toast.show("Видео сохранено и скопировано", "Вставьте ⌘V в чат. Файл — в «Фильмы → Снимки».", seconds: 4)
        }
    }

    nonisolated func recordingOutput(_ o: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.stop()
            Toast.show("Запись прервалась", error.localizedDescription, seconds: 6)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.stop() }
    }
}
