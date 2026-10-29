import Foundation
import SwiftUI

struct CoreState: Identifiable {
    let id: Int
    let kind: CoreKind
    let load: Double          // 0…1
    let mhz: Double?          // nil — ядро спит
}

struct HistoryPoint: Identifiable {
    let id: Int
    let total: Double
    let cpu: Double
    let gpu: Double
    let load: Double          // средняя загрузка процессора 0…1
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var cores: [CoreState] = []
    @Published private(set) var cpuWatts = 0.0
    @Published private(set) var eWatts = 0.0
    @Published private(set) var pWatts = 0.0
    @Published private(set) var gpuWatts = 0.0
    @Published private(set) var ramWatts = 0.0
    @Published private(set) var aneWatts = 0.0
    @Published private(set) var socWatts = 0.0     // контроллер памяти, вывод на экран, видео, фото
    @Published private(set) var gpuLoad: Double?
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var memory = MemoryInfo()
    @Published private(set) var thermal = ProcessInfo.ThermalState.nominal
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var smoothWatts: Double?

    let layout = CoreLayout.read()
    var panelOpen = false { didSet { if panelOpen && !oldValue { tick(); refreshApps() } } }

    private let report = IOReport()
    private let coreLoad = CoreLoad()
    private var timer: Timer?
    private var tickNo = 0
    private var appsBusy = false

    init() {
        _ = coreLoad.sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    var hasEnergy: Bool { report != nil }

    private func tick() {
        tickNo += 1
        // Окно закрыто — нужна только надпись в строке меню: батарея раз в 5 секунд, остальное не трогаем.
        guard panelOpen else {
            if tickNo % 5 == 0 { readBattery() }
            return
        }
        let loads = coreLoad.sample()
        let s = report?.sample()
        if let s {
            cpuWatts = s.watts["CPU Energy"] ?? ((s.watts["ECPU"] ?? 0) + (s.watts["PCPU"] ?? 0))
            eWatts = s.watts["ECPU"] ?? 0
            pWatts = s.watts["PCPU"] ?? 0
            gpuWatts = s.watts["GPU Energy"] ?? s.watts["GPU"] ?? 0
            ramWatts = s.watts["DRAM"] ?? 0
            aneWatts = s.watts["ANE"] ?? 0
            socWatts = ["AMCC", "DCS", "DISP", "DISPEXT", "ISP", "AVE", "VDEC", "VENC", "MSR", "SOC_AON", "PCIe", "ProRes"]
                .reduce(0) { $0 + (s.watts[$1] ?? 0) }
        }
        var eIndex = 0, pIndex = 0
        cores = layout.kinds.enumerated().map { i, kind in
            let channel: String
            let table: [Double]
            if kind == .efficiency { channel = "ECPU\(eIndex)"; eIndex += 1; table = layout.eFreqMHz }
            else { channel = "PCPU\(pIndex)"; pIndex += 1; table = layout.pFreqMHz }
            return CoreState(id: i, kind: kind, load: i < loads.count ? loads[i] : 0,
                             mhz: s.flatMap { Self.frequency($0.residency[channel], table: table) })
        }
        gpuLoad = GPUInfo.utilization()
        readBattery()
        if tickNo % 2 == 1 { memory = MemoryInfo.read() }
        thermal = ProcessInfo.processInfo.thermalState
        let avgLoad = loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
        history.append(HistoryPoint(id: tickNo, total: battery?.systemWatts ?? (cpuWatts + gpuWatts + ramWatts),
                                    cpu: cpuWatts, gpu: gpuWatts, load: avgLoad))
        if history.count > 120 { history.removeFirst(history.count - 120) }
        if panelOpen, tickNo % 3 == 0 { refreshApps() }
    }

    private func readBattery() {
        battery = BatteryInfo.read()
        if let w = battery?.systemWatts, w > 0 {
            // Сглаживаем, чтобы запас батареи не прыгал от каждого всплеска (окно ~20 секунд).
            smoothWatts = smoothWatts.map { $0 * 0.95 + w * 0.05 } ?? w
        }
    }

    private func refreshApps() {
        guard !appsBusy else { return }
        appsBusy = true
        Task.detached(priority: .utility) {
            let list = ProcessList.top()
            await MainActor.run {
                self.apps = list
                self.appsBusy = false
            }
        }
    }

    /// Средняя частота за последний замер по времени на каждой ступени.
    nonisolated static func frequency(_ steps: [Int: Double]?, table: [Double]) -> Double? {
        guard let steps, !table.isEmpty else { return nil }
        var sum = 0.0, time = 0.0
        for (v, t) in steps where t > 0 {
            sum += t * table[min(v, table.count - 1)]
            time += t
        }
        return time > 0 ? sum / time : nil
    }

    // MARK: - Подсчёты для экрана

    var eLoad: Double { avg(cores.filter { $0.kind == .efficiency }.map(\.load)) }
    var pLoad: Double { avg(cores.filter { $0.kind == .performance }.map(\.load)) }
    var eMHz: Double? { avgOpt(cores.filter { $0.kind == .efficiency }.compactMap(\.mhz)) }
    var pMHz: Double? { avgOpt(cores.filter { $0.kind == .performance }.compactMap(\.mhz)) }

    /// Часов работы от батареи при нынешней нагрузке.
    var hoursLeft: Double? {
        guard let b = battery, !b.external, let w = smoothWatts, w > 0.3 else { return nil }
        return b.whNow / w
    }

    /// Часов до полной зарядки (примерно: под конец зарядка замедляется).
    var hoursToFull: Double? {
        guard let b = battery, b.external, b.batteryWatts > 0.5, b.percent < 100 else { return nil }
        return (b.whMax - b.whNow) / b.batteryWatts
    }

    /// Сколько примерно прибавится работы, если закрыть программу.
    func gain(for app: AppUsage) -> Double? {
        guard let b = battery, !b.external, let w = smoothWatts, w > 1 else { return nil }
        let totalCPU = apps.reduce(0) { $0 + $1.cpu }
        guard totalCPU > 0 else { return nil }
        let appWatts = cpuWatts * app.cpu / totalCPU
        guard appWatts > 0.2, w - appWatts > 0.5 else { return nil }
        let delta = b.whNow / (w - appWatts) - b.whNow / w
        return delta >= 5.0 / 60 ? delta : nil
    }

    var menuTitle: String {
        guard let b = battery else { return rf("%.0f%%", (eLoad + pLoad) * 50) }
        if b.adapterButNoPower { return "⚠︎ 0 Вт" }
        if b.external, let w = b.inputWatts, w >= 1 { return rf("⚡︎%.0f Вт", w) }
        if b.external { return "⚡︎ \(b.percent)%" }
        let w = b.systemWatts ?? 0
        if let h = hoursLeft { return rf("%.0f Вт · %@", w, Self.hm(h)) }
        return rf("%.0f Вт", w)
    }

    static func hm(_ hours: Double) -> String {
        let m = Int((hours * 60).rounded())
        return "\(m / 60):" + rf("%02d", m % 60)
    }

    private func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    private func avgOpt(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
}
