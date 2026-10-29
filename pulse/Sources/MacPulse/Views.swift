import Charts
import ServiceManagement
import SwiftUI

// Тёмная тема: почти чёрный фон, карточки чуть светлее, синий акцент.
enum Palette {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let card = Color(red: 0.067, green: 0.067, blue: 0.078)
    static let line = Color.white.opacity(0.07)
    static let brand = Color(red: 0.106, green: 0.369, blue: 0.894)
    static let dim = Color.white.opacity(0.55)
    static let green = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let amber = Color(red: 0.98, green: 0.70, blue: 0.20)
    static let red = Color(red: 0.96, green: 0.33, blue: 0.33)
    static let violet = Color(red: 0.56, green: 0.52, blue: 0.91)

    static func load(_ v: Double) -> Color { v < 0.35 ? green : v < 0.75 ? amber : red }
}

struct PanelView: View {
    @EnvironmentObject var m: Monitor
    @StateObject private var cleaner: Cleaner
    @State private var tab: Int

    init(initialTab: Int = 0, cleaner: Cleaner? = nil) {
        _tab = State(initialValue: initialTab)
        _cleaner = StateObject(wrappedValue: cleaner ?? Cleaner())
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            Picker("", selection: $tab) {
                Text("Сейчас").tag(0)
                Text("Программы").tag(1)
                Text("Очистка").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(spacing: 10) {
                    switch tab {
                    case 0: NowTab()
                    case 1: AppsTab()
                    default: CleanerTab(cleaner: cleaner)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            footer
        }
        .padding(14)
        .frame(width: 400, height: 640)
        .background(Palette.bg)
        .environment(\.colorScheme, .dark)
        .background(WindowVisibility { visible in m.panelOpen = visible })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Пульс").font(.system(size: 18, weight: .bold))
            Text(m.layout.chip).font(.system(size: 12)).foregroundStyle(Palette.dim)
            Spacer()
            ThermalBadge(state: m.thermal)
        }
    }

    private var footer: some View {
        HStack {
            LoginToggle()
            Spacer()
            Button("Выйти") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.dim)
        }
        .font(.system(size: 12))
    }
}

// MARK: - «Сейчас»

struct NowTab: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        PowerCard()
        CoresCard()
        if m.hasEnergy { EnergyCard() }
        ChartCard()
        GPUMemoryCard()
        BatteryCard()
    }
}

struct PowerCard: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        Card {
            if let b = m.battery {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    if b.external {
                        Text(rf("%.0f", b.inputWatts ?? 0)).font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Вт от зарядки").foregroundStyle(Palette.dim)
                    } else {
                        Text(rf("%.1f", b.systemWatts ?? 0)).font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Вт ест Mac").foregroundStyle(Palette.dim)
                    }
                    Spacer()
                    Text("\(b.percent)%").font(.system(size: 22, weight: .semibold, design: .rounded))
                }
                .monospacedDigit()
                if b.adapterButNoPower {
                    Label("Зарядка подключена, но энергия не идёт. Нажмите кнопку на пауэрбанке или переподключите провод.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Palette.amber)
                } else if b.external {
                    let toFull = m.hoursToFull.map { " · до 100% ≈ \(Monitor.hm($0))" } ?? ""
                    let deal = b.adapterWatts.map { rf("договорились на %.0f Вт", $0) } ?? "зарядка подключена"
                    Text(b.fullyCharged || b.percent >= 100 ? "Заряжено полностью · \(deal)"
                         : rf("В батарею %.0f Вт · %@%@", max(b.batteryWatts, 0), deal, toFull))
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                } else if let h = m.hoursLeft {
                    (Text("Хватит на ") + Text(Monitor.hm(h)).bold().foregroundColor(.white)
                     + Text(" при такой нагрузке" + (b.macMinutesLeft.map { " · macOS думает \(Monitor.hm(Double($0) / 60))" } ?? "")))
                    .font(.system(size: 12)).foregroundStyle(Palette.dim)
                }
            } else {
                Text("Батареи нет — это настольный Mac").foregroundStyle(Palette.dim)
            }
        }
    }
}

struct CoresCard: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        Card {
            CoreRow(title: "Производительные", cores: m.cores.filter { $0.kind == .performance },
                    load: m.pLoad, mhz: m.pMHz, watts: m.hasEnergy ? m.pWatts : nil)
            Divider().overlay(Palette.line)
            CoreRow(title: "Экономичные", cores: m.cores.filter { $0.kind == .efficiency },
                    load: m.eLoad, mhz: m.eMHz, watts: m.hasEnergy ? m.eWatts : nil)
        }
    }
}

struct CoreRow: View {
    let title: String
    let cores: [CoreState]
    let load: Double
    let mhz: Double?
    let watts: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(title) · \(cores.count)").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(summary).font(.system(size: 12)).foregroundStyle(Palette.dim).monospacedDigit()
            }
            HStack(spacing: 6) {
                ForEach(cores) { CoreCell(core: $0) }
            }
        }
    }

    private var summary: String {
        var parts = ["\(Int((load * 100).rounded()))%"]
        if let mhz { parts.append(ghz(mhz)) }
        if let watts { parts.append(rf("%.1f Вт", watts)) }
        return parts.joined(separator: " · ")
    }
}

struct CoreCell: View {
    let core: CoreState

    var body: some View {
        let color = Palette.load(core.load)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05))
            GeometryReader { g in
                VStack { Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.85))
                        .frame(height: max(3, g.size.height * core.load))
                        .animation(.easeOut(duration: 0.5), value: core.load)
                }
            }
            VStack(spacing: 1) {
                Text("\(Int((core.load * 100).rounded()))").font(.system(size: 13, weight: .bold, design: .rounded))
                Text(core.mhz.map(ghzShort) ?? "сон").font(.system(size: 9)).opacity(0.75)
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 46)
        .help("Ядро \(core.id): загрузка \(Int(core.load * 100))%" + (core.mhz.map { ", " + ghz($0) } ?? ", спит"))
    }
}

struct EnergyCard: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        let total = m.battery?.systemWatts
        let known = m.cpuWatts + m.gpuWatts + m.ramWatts + m.aneWatts + m.socWatts
        var rows: [(String, Double, Color)] = [
            ("Процессор", m.cpuWatts, Palette.brand),
            ("Видеокарта", m.gpuWatts, Palette.violet),
            ("Память", m.ramWatts, Palette.green),
        ]
        if m.aneWatts > 0.01 { rows.append(("Нейроядро", m.aneWatts, Palette.amber)) }
        rows.append(("Остальной чип", m.socWatts, Color.white.opacity(0.6)))
        if let t = total, t > known { rows.append(("Экран, Wi-Fi, диск", t - known, Color.white.opacity(0.3))) }
        let top = max(rows.map(\.1).max() ?? 1, 0.1)

        return Card {
            Text("Куда уходит энергия").font(.system(size: 13, weight: .semibold))
            ForEach(rows, id: \.0) { name, w, color in
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 12)).frame(width: 150, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(color)
                            .frame(width: max(2, g.size.width * w / top))
                    }
                    .frame(height: 8)
                    Text(rf("%.2f Вт", w)).font(.system(size: 12)).monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
    }
}

struct ChartCard: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        Card {
            Text("Последние 2 минуты").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                Legend(color: .white, text: "весь Mac")
                Legend(color: Palette.brand, text: "процессор")
                Legend(color: Palette.violet, text: "видеокарта")
            }
            Chart(m.history) { p in
                LineMark(x: .value("t", p.id), y: .value("Вт", p.total), series: .value("s", "all"))
                    .foregroundStyle(.white)
                LineMark(x: .value("t", p.id), y: .value("Вт", p.cpu), series: .value("s", "cpu"))
                    .foregroundStyle(Palette.brand)
                LineMark(x: .value("t", p.id), y: .value("Вт", p.gpu), series: .value("s", "gpu"))
                    .foregroundStyle(Palette.violet)
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Palette.line)
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) Вт").font(.system(size: 9)) } }
            } }
            .frame(height: 110)
        }
    }
}

struct GPUMemoryCard: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Видеокарта").font(.system(size: 13, weight: .semibold))
                    Text(m.gpuLoad.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Bar(value: m.gpuLoad ?? 0, color: Palette.violet)
                }
                Spacer(minLength: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Память").font(.system(size: 13, weight: .semibold))
                    Text(rf("%.1f из %.0f ГБ", m.memory.usedGB, m.memory.totalGB))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Bar(value: m.memory.totalGB > 0 ? m.memory.usedGB / m.memory.totalGB : 0, color: pressureColor)
                    Text(pressureText).font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
            }
            .monospacedDigit()
        }
    }

    private var pressureColor: Color { m.memory.pressure >= 4 ? Palette.red : m.memory.pressure >= 2 ? Palette.amber : Palette.green }
    private var pressureText: String {
        let p = m.memory.pressure >= 4 ? "памяти не хватает" : m.memory.pressure >= 2 ? "памяти тесно" : "памяти хватает"
        return m.memory.swapGB >= 0.1 ? p + rf(" · на диске %.1f ГБ", m.memory.swapGB) : p
    }
}

struct BatteryCard: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        if let b = m.battery {
            Card {
                Text("Батарея").font(.system(size: 13, weight: .semibold))
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Key("Здоровье"); Val("\(Int((b.health * 100).rounded()))% от новой") }
                    GridRow { Key("Вмещает"); Val(rf("%.0f из %.0f мА·ч · %.0f Вт·ч", b.mAhMax, b.mAhDesign, b.whMax)) }
                    GridRow { Key("Сейчас в ней"); Val(rf("%.0f мА·ч · %.1f Вт·ч", b.mAhNow, b.whNow)) }
                    GridRow { Key("Циклов"); Val("\(b.cycles)") }
                    GridRow { Key("Температура"); Val(rf("%.1f °C", b.tempC)) }
                    GridRow { Key("Ток"); Val(rf("%+.2f А при %.2f В", b.amperage, b.voltage)) }
                }
                .monospacedDigit()
            }
        }
    }
}

// MARK: - «Программы»

struct AppsTab: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        Card {
            HStack {
                Text("Кто нагружает Mac").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("процессор · память").font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
            if m.apps.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(m.apps.prefix(15)) { app in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(app.name).font(.system(size: 13)).lineLimit(1)
                        if app.processes > 1 { Text("×\(app.processes)").font(.system(size: 10)).foregroundStyle(Palette.dim) }
                        Spacer()
                        Text(rf("%.0f%%", app.cpu)).foregroundStyle(Palette.load(min(app.cpu / 100, 1)))
                        Text(memText(app.memMB)).foregroundStyle(Palette.dim).frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    if let g = m.gain(for: app) {
                        Text("≈ +\(Monitor.hm(g)) работы от батареи, если закрыть")
                            .font(.system(size: 11)).foregroundStyle(Palette.green)
                    }
                }
                Divider().overlay(Palette.line)
            }
            Text("100% — одно ядро загружено полностью. Прибавка работы — примерная, по доле процессора.")
                .font(.system(size: 10)).foregroundStyle(Palette.dim)
        }
    }

    private func memText(_ mb: Double) -> String { mb >= 1024 ? rf("%.1f ГБ", mb / 1024) : rf("%.0f МБ", mb) }
}

// MARK: - «Очистка»

struct CleanerTab: View {
    @ObservedObject var cleaner: Cleaner
    @State private var confirm = false

    var body: some View {
        switch cleaner.phase {
        case .idle:
            Card {
                Text("Очистка кэша").font(.system(size: 15, weight: .semibold))
                Text("Найду временные файлы программ, журналы и кэши сборки. Сначала покажу, что и сколько весит, — вы решите. Выбранное уйдёт в Корзину, а не сотрётся насовсем. Системные файлы и ваши данные не трогаю.")
                    .font(.system(size: 12)).foregroundStyle(Palette.dim)
                Button { cleaner.scan() } label: { Text("Найти").frame(maxWidth: .infinity) }
                    .buttonStyle(BrandButton())
            }
        case .scanning:
            Card { HStack { ProgressView().controlSize(.small); Text("Считаю, сколько весит…") } }
        case .cleaning:
            Card { HStack { ProgressView().controlSize(.small); Text("Переношу в Корзину…") } }
        case .done:
            Card {
                Text("Готово: в Корзине \(bytesText(cleaner.movedBytes))").font(.system(size: 15, weight: .semibold))
                Text("Место освободится, когда очистите Корзину (правый клик по Корзине в Доке → «Очистить Корзину»). До этого всё можно вернуть.")
                    .font(.system(size: 12)).foregroundStyle(Palette.dim)
                if !cleaner.failures.isEmpty {
                    Text("Не получилось перенести (заняты или защищены): " + cleaner.failures.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(Palette.amber)
                }
                Button("Найти ещё раз") { cleaner.scan() }
            }
        case .ready:
            if cleaner.groups.isEmpty {
                Card { Text("Чистить нечего — мусора больше 1 МБ не нашлось.").foregroundStyle(Palette.dim) }
            }
            ForEach(cleaner.groups) { g in GroupCard(group: g, cleaner: cleaner) }
            Button {
                confirm = true
            } label: {
                Text("В Корзину: \(bytesText(cleaner.selectedBytes))").frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandButton())
            .disabled(cleaner.selectedBytes == 0)
            .confirmationDialog("Перенести выбранное в Корзину?", isPresented: $confirm) {
                Button("В Корзину") { cleaner.moveSelectedToTrash() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Лучше сначала закрыть браузеры и программы из списка. Вернуть можно из Корзины.")
            }
        }
    }
}

struct GroupCard: View {
    let group: CleanGroup
    @ObservedObject var cleaner: Cleaner
    @State private var open = CommandLine.arguments.contains("--snapshot")

    var body: some View {
        Card {
            HStack {
                Toggle(isOn: Binding(get: { group.items.filter { $0.note == nil }.allSatisfy(\.selected) },
                                     set: { cleaner.setAll(group: group.id, $0) })) {
                    Text(group.title).font(.system(size: 13, weight: .semibold))
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text(bytesText(group.bytes)).monospacedDigit()
                Button(open ? "Скрыть" : "Подробно") { open.toggle() }.buttonStyle(.plain).foregroundStyle(Palette.brand)
            }
            Text(group.hint).font(.system(size: 11)).foregroundStyle(Palette.dim)
            if open {
                ForEach(group.items) { item in
                    HStack {
                        Toggle(isOn: Binding(get: { item.selected }, set: { _ in cleaner.toggle(group: group.id, item: item.id) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                if let note = item.note { Text(note).font(.system(size: 10)).foregroundStyle(Palette.amber) }
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        Text(bytesText(item.bytes)).foregroundStyle(Palette.dim).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .help(item.id.path)
                }
            }
        }
    }
}

// MARK: - Детали

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }
}

/// Открыто ли окно на самом деле. macOS готовит окно строки меню заранее и держит его «видимым» —
/// поэтому смотрим на активность: окно активно, только пока вы его открыли.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(onChange: onChange) }
    func updateNSView(_ view: Watcher, context: Context) {}

    final class Watcher: NSView {
        let onChange: (Bool) -> Void
        private var tokens: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let w = window else { onChange(false); return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.willCloseNotification]
            for n in names {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] note in
                    guard let self, let w = self.window else { return }
                    self.onChange(note.name != NSWindow.willCloseNotification && w.isKeyWindow)
                })
            }
            onChange(w.isKeyWindow)
        }
    }
}

struct BrandButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.brand.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)))
            .contentShape(Rectangle())
    }
}

struct Bar: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.5), value: value)
    }
}

struct Legend: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(Palette.dim)
        }
    }
}

struct ThermalBadge: View {
    let state: ProcessInfo.ThermalState
    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .nominal: ("не греется", Palette.green)
        case .fair: ("тёплый", Palette.amber)
        case .serious: ("горячий — сбавляет скорость", Palette.red)
        case .critical: ("перегрев", Palette.red)
        @unknown default: ("—", Palette.dim)
        }
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

struct LoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    var body: some View {
        Toggle("Запускать при входе", isOn: Binding(get: { on }, set: { v in
            do {
                if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                on = v; error = nil
            } catch { self.error = "не вышло: \(error.localizedDescription)" }
        }))
        .toggleStyle(.switch).controlSize(.mini)
        .help(error ?? "Пульс будет сам появляться в строке меню после включения Mac")
    }
}

private func Key(_ s: String) -> some View { Text(s).font(.system(size: 12)).foregroundStyle(Palette.dim) }
private func Val(_ s: String) -> some View { Text(s).font(.system(size: 12)) }
func ghz(_ mhz: Double) -> String { rf("%.2f ГГц", mhz / 1000) }
func ghzShort(_ mhz: Double) -> String { rf("%.1f", mhz / 1000) }
