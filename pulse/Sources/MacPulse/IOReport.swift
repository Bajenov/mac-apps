import Foundation

// Обёртка над системной библиотекой IOReport (та же, что у powermetrics).
// Даёт энергию процессора, видеокарты, памяти и время на каждой ступени частоты — без пароля администратора.
final class IOReport {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias MergeChannels = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleInt = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyChannels: CopyChannels
    private let mergeChannels: MergeChannels
    private let createSubscription: CreateSubscription
    private let createSamples: CreateSamples
    private let samplesDelta: SamplesDelta
    private let channelName: ChannelString
    private let channelGroup: ChannelString
    private let unitLabel: ChannelString
    private let simpleInt: SimpleInt
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency

    private var subscription: OpaquePointer?
    private var subscribed: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousAt = Date()

    init?() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let a: CopyChannels = load("IOReportCopyChannelsInGroup"),
              let b: MergeChannels = load("IOReportMergeChannels"),
              let c: CreateSubscription = load("IOReportCreateSubscription"),
              let d: CreateSamples = load("IOReportCreateSamples"),
              let e: SamplesDelta = load("IOReportCreateSamplesDelta"),
              let f: ChannelString = load("IOReportChannelGetChannelName"),
              let g: ChannelString = load("IOReportChannelGetGroup"),
              let j: ChannelString = load("IOReportChannelGetUnitLabel"),
              let k: SimpleInt = load("IOReportSimpleGetIntegerValue"),
              let l: StateCount = load("IOReportStateGetCount"),
              let m: StateName = load("IOReportStateGetNameForIndex"),
              let n: StateResidency = load("IOReportStateGetResidency")
        else { return nil }
        copyChannels = a; mergeChannels = b; createSubscription = c; createSamples = d; samplesDelta = e
        channelName = f; channelGroup = g; unitLabel = j; simpleInt = k
        stateCount = l; stateName = m; stateResidency = n

        guard let energy = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let cpu = copyChannels("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let all = CFDictionaryCreateMutableCopy(nil, 0, energy)
        else { return nil }
        mergeChannels(all, cpu, nil)
        var out: Unmanaged<CFMutableDictionary>?
        subscription = createSubscription(nil, all, &out, 0, nil)
        guard subscription != nil, let s = out?.takeRetainedValue() else { return nil }
        subscribed = s
        previous = createSamples(subscription, s, nil)?.takeRetainedValue()
    }

    struct Sample {
        /// Мощность по каналам «Энергии», Вт: "CPU Energy", "GPU Energy", "DRAM", "ECPU", "PCPU", "ANE"…
        var watts: [String: Double] = [:]
        /// Время на ступенях частоты по ядрам: "ECPU0" → [номер ступени V: время].
        var residency: [String: [Int: Double]] = [:]
        /// Время в простое по ядрам.
        var idle: [String: Double] = [:]
    }

    func sample() -> Sample? {
        guard let s = subscribed, let prev = previous,
              let now = createSamples(subscription, s, nil)?.takeRetainedValue() else { return nil }
        let at = Date()
        let seconds = max(at.timeIntervalSince(previousAt), 0.05)
        defer { previous = now; previousAt = at }
        guard let delta = samplesDelta(prev, now, nil)?.takeRetainedValue() as NSDictionary?,
              let channels = delta["IOReportChannels"] as? [NSDictionary] else { return nil }

        var result = Sample()
        for ch in channels {
            let cf = ch as CFDictionary
            let name = channelName(cf)?.takeUnretainedValue() as String? ?? ""
            let group = channelGroup(cf)?.takeUnretainedValue() as String? ?? ""
            if group == "Energy Model" {
                let unit = (unitLabel(cf)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
                let raw = Double(simpleInt(cf, 0))
                let joules: Double
                switch unit {
                case "mJ": joules = raw / 1e3
                case "uJ", "µJ": joules = raw / 1e6
                case "nJ": joules = raw / 1e9
                default: continue
                }
                result.watts[name, default: 0] += joules / seconds
            } else if group == "CPU Stats" {
                let count = stateCount(cf)
                guard count > 0 else { continue }
                var steps: [Int: Double] = [:]
                var idle = 0.0
                for i in 0..<count {
                    let state = stateName(cf, i)?.takeUnretainedValue() as String? ?? ""
                    let r = Double(stateResidency(cf, i))
                    if let v = Self.stepIndex(state) { steps[v, default: 0] += r } else { idle += r }
                }
                result.residency[name] = steps
                result.idle[name] = idle
            }
        }
        return result
    }

    /// "V3P4" → 3; "IDLE", "OFF", "DOWN" → nil.
    private static func stepIndex(_ state: String) -> Int? {
        guard state.hasPrefix("V") else { return nil }
        return Int(state.dropFirst().prefix { $0.isNumber })
    }
}
