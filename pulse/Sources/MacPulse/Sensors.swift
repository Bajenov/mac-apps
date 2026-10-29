import Foundation
import IOKit

// MARK: - Процессор: ядра и таблицы частот

enum CoreKind { case efficiency, performance }

struct CoreLayout {
    let kinds: [CoreKind]          // по номеру ядра
    let eFreqMHz: [Double]         // ступени частоты экономичных ядер
    let pFreqMHz: [Double]         // ступени частоты производительных ядер
    let chip: String

    static func read() -> CoreLayout {
        let e = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        let p = sysctlInt("hw.perflevel0.logicalcpu") ?? sysctlInt("hw.ncpu") ?? 0
        // На Apple Silicon экономичные ядра идут первыми номерами.
        let kinds = Array(repeating: CoreKind.efficiency, count: e) + Array(repeating: CoreKind.performance, count: p)
        return CoreLayout(kinds: kinds,
                          eFreqMHz: freqTable("voltage-states1-sram"),
                          pFreqMHz: freqTable("voltage-states5-sram"),
                          chip: sysctlString("machdep.cpu.brand_string") ?? "Apple")
    }

    /// Таблица частот из устройства pmgr: пары (частота, напряжение) по 4 байта.
    private static func freqTable(_ key: String) -> [Double] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return [] }
        var out: [Double] = []
        data.withUnsafeBytes { raw in
            var i = 0
            while i + 8 <= raw.count {
                let v = Double(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))
                // Старые чипы пишут частоту в герцах, новые — в килогерцах.
                out.append(v > 1e7 ? v / 1e6 : v / 1e3)
                i += 8
            }
        }
        return out
    }
}

/// Загрузка каждого ядра (0…1) по счётчикам тиков ядра системы.
final class CoreLoad {
    private var previous: [[UInt32]] = []

    func sample() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var now: [[UInt32]] = []
        for c in 0..<Int(count) {
            let base = c * Int(CPU_STATE_MAX)
            now.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { previous = now }
        guard previous.count == now.count else { return Array(repeating: 0, count: now.count) }
        return zip(now, previous).map { n, p in
            let d = (0..<n.count).map { Double(n[$0] &- p[$0]) }
            let busy = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            let total = busy + d[Int(CPU_STATE_IDLE)]
            return total > 0 ? busy / total : 0
        }
    }
}

// MARK: - Батарея и зарядка

struct BatteryInfo {
    var percent = 0
    var isCharging = false
    var external = false
    var fullyCharged = false
    var mAhNow = 0.0
    var mAhMax = 0.0
    var mAhDesign = 0.0
    var cycles = 0
    var tempC = 0.0
    var voltage = 0.0            // В
    var amperage = 0.0           // А, плюс — заряжается, минус — разряжается
    var systemWatts: Double?     // сколько ест весь Mac, Вт
    var inputWatts: Double?      // сколько приходит от зарядки, Вт
    var inputVolts: Double?
    var adapterWatts: Double?    // о чём договорились с зарядкой
    var macMinutesLeft: Int?     // оценка самой macOS

    var batteryWatts: Double { voltage * amperage }
    var health: Double { mAhDesign > 0 ? mAhMax / mAhDesign : 0 }
    var whNow: Double { mAhNow * voltage / 1000 }
    var whMax: Double { mAhMax * voltage / 1000 }
    var adapterButNoPower: Bool { external && !fullyCharged && (inputWatts ?? 0) < 1 && percent < 100 }

    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let keys = ["CurrentCapacity", "IsCharging", "ExternalConnected", "FullyCharged", "AppleRawCurrentCapacity",
                    "AppleRawMaxCapacity", "DesignCapacity", "CycleCount", "Temperature", "Voltage", "InstantAmperage",
                    "PowerTelemetryData", "AdapterDetails", "TimeRemaining"]
        var d: [String: Any] = [:]
        for k in keys {
            if let v = IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { d[k] = v }
        }
        guard !d.isEmpty else { return nil }
        func num(_ k: String, in dict: [String: Any]? = nil) -> NSNumber? { (dict ?? d)[k] as? NSNumber }

        var b = BatteryInfo()
        b.percent = num("CurrentCapacity")?.intValue ?? 0
        b.isCharging = num("IsCharging")?.boolValue ?? false
        b.external = num("ExternalConnected")?.boolValue ?? false
        b.fullyCharged = num("FullyCharged")?.boolValue ?? false
        b.mAhNow = num("AppleRawCurrentCapacity")?.doubleValue ?? 0
        b.mAhMax = num("AppleRawMaxCapacity")?.doubleValue ?? 0
        b.mAhDesign = num("DesignCapacity")?.doubleValue ?? 0
        b.cycles = num("CycleCount")?.intValue ?? 0
        b.tempC = (num("Temperature")?.doubleValue ?? 0) / 100
        b.voltage = (num("Voltage")?.doubleValue ?? 0) / 1000
        b.amperage = Double(num("InstantAmperage")?.int64Value ?? 0) / 1000
        if let t = d["PowerTelemetryData"] as? [String: Any] {
            if let load = num("SystemLoad", in: t)?.doubleValue, load > 0 { b.systemWatts = load / 1000 }
            if let p = num("SystemPowerIn", in: t)?.doubleValue { b.inputWatts = p / 1000 }
            if let v = num("SystemVoltageIn", in: t)?.doubleValue, v > 0 { b.inputVolts = v / 1000 }
        }
        if b.external, let a = d["AdapterDetails"] as? [String: Any] { b.adapterWatts = num("Watts", in: a)?.doubleValue }
        if let m = num("TimeRemaining")?.intValue, m > 0, m < 6000 { b.macMinutesLeft = m }
        if b.systemWatts == nil, !b.external { b.systemWatts = -b.batteryWatts }
        return b
    }
}

// MARK: - Видеокарта, память, тепло

enum GPUInfo {
    static func utilization() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, u / 100)
            }
        }
        return best
    }
}

struct MemoryInfo {
    var usedGB = 0.0
    var totalGB = 0.0
    var swapGB = 0.0
    var pressure = 1   // 1 — норма, 2 — тесно, 4 — критично

    static func read() -> MemoryInfo {
        var m = MemoryInfo()
        m.totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            // Как «Использовано памяти» в Мониторинге системы: память программ + неперемещаемая + сжатая.
            let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
            m.usedGB = used / 1_073_741_824
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapGB = Double(swap.xsu_used) / 1_073_741_824 }
        m.pressure = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return m
    }
}

// MARK: - Программы

struct AppUsage: Identifiable {
    var id: String { name }
    let name: String
    let cpu: Double        // проценты одного ядра, как в Мониторинге системы
    let memMB: Double
    let processes: Int
}

enum ProcessList {
    /// Программы по нагрузке; вспомогательные процессы складываются в свою программу (Chrome Helper → Google Chrome).
    static func top() -> [AppUsage] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aeo", "pcpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var groups: [String: (cpu: Double, mem: Double, n: Int)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
                  let rss = Double(parts[1]) else { continue }
            let name = appName(String(parts[2]))
            var g = groups[name] ?? (0, 0, 0)
            g.cpu += cpu; g.mem += rss / 1024; g.n += 1
            groups[name] = g
        }
        return groups.map { AppUsage(name: $0.key, cpu: $0.value.cpu, memMB: $0.value.mem, processes: $0.value.n) }
            .sorted { $0.cpu > $1.cpu }
    }

    static func appName(_ path: String) -> String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        if base.hasPrefix("com.apple.WebKit") { return "Веб-страницы (Safari и др.)" }
        if base == "WindowServer" { return "Вывод на экран (WindowServer)" }
        if base == "kernel_task" { return "Ядро macOS" }
        if let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) {
            let head = path[..<r.lowerBound]
            return head.split(separator: "/").last.map(String.init) ?? path
        }
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - Мелочи

private let ruLocale = Locale(identifier: "ru_RU")
/// Как String(format:), но с запятой в дробях: 11,4 Вт.
func rf(_ format: String, _ args: CVarArg...) -> String { String(format: format, locale: ruLocale, arguments: args) }

func sysctlInt(_ name: String) -> Int? {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}
