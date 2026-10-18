#if os(macOS)
import Foundation
import SwiftUI
import AutoScanCore

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case overview, faults, live, norm, packs, log
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Огляд"
        case .faults: return "Помилки"
        case .live: return "Живі дані"
        case .norm: return "Норма vs зараз"
        case .packs: return "Бази авто"
        case .log: return "Журнал адаптера"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.medium"
        case .faults: return "exclamationmark.triangle"
        case .live: return "waveform.path.ecg"
        case .norm: return "chart.line.uptrend.xyaxis"
        case .packs: return "shippingbox"
        case .log: return "list.bullet.rectangle"
        }
    }
}

enum ConnectionKind: String, CaseIterable, Identifiable {
    case demo, usb, wifi, bluetooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .demo: return "Демо"
        case .usb: return "USB / кабель"
        case .wifi: return "Wi‑Fi"
        case .bluetooth: return "Bluetooth"
        }
    }
    var icon: String {
        switch self {
        case .demo: return "play.circle"
        case .usb: return "cable.connector"
        case .wifi: return "wifi"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting(String)
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }
    var isBusy: Bool { if case .connecting = self { return true }; return false }
}

@MainActor
final class AppModel: ObservableObject {
    // Навігація
    @Published var screen: Screen = .overview { didSet { updatePollPlan() } }
    @Published var showConnectSheet = false

    // Підключення
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var adapterName = ""
    @Published private(set) var connInfo = ConnectionInfo()
    @Published private(set) var isDemo = false
    @Published private(set) var demoScenario: DemoScenario?

    // Авто
    @Published private(set) var vin: VINInfo?
    @Published private(set) var monitor: MonitorStatus?
    @Published var manualBrand: String = UserDefaults.standard.string(forKey: "manualBrand") ?? "" {
        didSet { UserDefaults.standard.set(manualBrand, forKey: "manualBrand") }
    }

    // Помилки
    @Published private(set) var dtcs: [DTC] = []
    @Published private(set) var isReadingDTCs = false
    @Published private(set) var lastDTCRead: Date?
    @Published private(set) var isClearing = false

    // Живі дані — окремі об'єкти, щоб їхні часті оновлення не перемальовували все вікно
    let live = LiveStore()
    let logStore = LogStore()
    @Published var selectedPIDs: [UInt8] {
        didSet {
            UserDefaults.standard.set(selectedPIDs.map(Int.init), forKey: "selectedPIDs")
            updatePollPlan()
        }
    }
    @Published var livePaused = false { didSet { updatePollPlan() } }

    @Published var alertMessage: String?

    let database = DTCDatabase()
    @Published private(set) var packs: [BrandPack] = []

    // Каталог пакетів в інтернеті
    enum CatalogState: Equatable { case idle, loading, loaded, failed(String) }
    @Published private(set) var catalog: [PackCatalog.Item] = []
    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var installingPackID: String?

    private var service: OBDService?
    private var transport: OBDTransport?
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    /// Що опитувати зараз — оновлюється при зміні екрана, читається фоновим опитуванням.
    private let pollPlan = PollPlan()

    init() {
        if let saved = UserDefaults.standard.array(forKey: "selectedPIDs") as? [Int], !saved.isEmpty {
            selectedPIDs = saved.map { UInt8($0) }
        } else {
            selectedPIDs = PIDTable.defaultSelection
        }
        packs = database.packs
        Task { await loadCatalog() }
        // Єдиний «пульс» оновлення екрана: 4 рази на секунду
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                self.live.flush()
                self.logStore.flush()
            }
        }
    }

    // MARK: Похідні значення

    var brand: String? {
        if !manualBrand.isEmpty { return manualBrand }
        return vin?.brandKey
    }

    var supportedPIDs: Set<UInt8> { service?.supportedPIDs ?? [] }

    func isSupported(_ pid: UInt8) -> Bool {
        guard let s = service else { return true }
        return s.isSupported(pid)
    }

    func entry(for dtc: DTC) -> (entry: DTCEntry, source: String) {
        database.lookup(dtc.code, brand: brand)
    }

    var activePacks: [BrandPack] { database.packs(forBrand: brand) }

    func normContext(_ live: LiveStore) -> NormContext {
        NormContext(current: live.values, history: live.history, isDiesel: monitor?.isDiesel ?? false)
    }

    /// Перевірки «норма vs зараз» лише для сигналів, які це авто реально передає.
    func checks(for code: String) -> [NormCheck] {
        NormRules.checks(for: code).filter { isSupported($0.pid) }
    }

    // MARK: Підключення

    func connect(kind: ConnectionKind, serialPath: String = "", baud: Int = 0,
                 host: String = "192.168.0.10", port: UInt16 = 35000, bleDevice: BLEDevice? = nil,
                 demo: DemoScenario = .default) {
        disconnect(silently: true)
        isDemo = kind == .demo
        demoScenario = kind == .demo ? demo : nil
        connection = .connecting("Підключення до адаптера…")
        logStore.clear()
        vin = nil; monitor = nil; dtcs = []

        // Для USB без вибраної швидкості — пробуємо найпоширеніші по черзі
        let bauds = baud > 0 ? [baud] : [38400, 115200, 9600, 230400, 500000]
        let makeTransport: (Int) -> OBDTransport? = { b in
            switch kind {
            case .demo: return DemoTransport(scenario: demo)
            case .usb: return SerialTransport(path: serialPath, baudRate: b)
            case .wifi: return TCPTransport(host: host, port: port)
            case .bluetooth:
                guard let d = bleDevice else { return nil }
                return BLETransport(deviceID: d.id, deviceName: d.name)
            }
        }
        let attempts = kind == .usb ? bauds : [0]
        let logStore = self.logStore

        Task {
            var lastError: Error = AdapterError.notConnected
            for (i, b) in attempts.enumerated() {
                guard let t = makeTransport(b) else { break }
                if kind == .usb && attempts.count > 1 {
                    self.connection = .connecting("Пробую швидкість \(b) (\(i + 1) з \(attempts.count))…")
                }
                let session = ELM327Session(transport: t)
                session.onLog = { line in logStore.record(line) }
                t.onDisconnect = { [weak self] reason in
                    Task { @MainActor in self?.handleDrop(reason) }
                }
                let svc = OBDService(session: session)
                do {
                    try await t.open()
                    if kind == .usb && attempts.count > 1 {
                        // Швидка перевірка: чи відповідає адаптер на цій швидкості
                        let r = try await session.command("ATI", timeout: 1.5)
                        guard r.uppercased().contains("ELM") || r.uppercased().contains("OBD") || r.uppercased().contains("STN") else {
                            throw AdapterError.timeout
                        }
                    }
                    try await svc.initialize { [weak self] text in
                        Task { @MainActor in
                            guard let self else { return }
                            if case .connecting = self.connection { self.connection = .connecting(text) }
                        }
                    }
                    self.transport = t
                    self.service = svc
                    self.adapterName = t.displayName
                    self.connInfo = svc.info
                    self.connection = .connected
                    self.showConnectSheet = false
                    await self.readVehicle()
                    await self.readDTCs()
                    self.updatePollPlan()
                    self.startPolling()
                    return
                } catch {
                    t.close()
                    lastError = error
                    // Якщо адаптер відповів, але авто ні — інші швидкості не допоможуть
                    if let e = error as? AdapterError, e == .unableToConnect || e == .canError { break }
                }
            }
            self.transport = nil
            self.service = nil
            var message = Self.describe(lastError)
            if kind == .usb, attempts.count > 1, (lastError as? AdapterError) == .timeout {
                message = "Адаптер не відповідає. Перевірте, що вибрано правильний пристрій і адаптер вставлений у машину (на ньому має світитися лампочка)."
            }
            self.connection = .failed(message)
        }
    }

    func disconnect(silently: Bool = false) {
        pollTask?.cancel()
        pollTask = nil
        transport?.close()
        transport = nil
        service = nil
        if !silently {
            connection = .disconnected
            isDemo = false
            demoScenario = nil
        }
        live.reset(keepValues: false)
    }

    private func handleDrop(_ reason: String) {
        guard connection.isConnected else { return }
        disconnect(silently: true)
        connection = .failed(reason)
        alertMessage = reason
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? AdapterError { return e.description }
        return error.localizedDescription
    }

    // MARK: Читання

    func readVehicle() async {
        guard let svc = service else { return }
        if let v = try? await svc.readVIN() { vin = VINInfo(vin: v) } else { vin = nil }
        monitor = try? await svc.monitorStatus()
    }

    func readDTCs() async {
        guard let svc = service, !isReadingDTCs else { return }
        isReadingDTCs = true
        defer { isReadingDTCs = false }
        var all: [DTC] = []
        do {
            all += try await svc.readDTCs(kind: .stored)
            all += (try? await svc.readDTCs(kind: .pending)) ?? []
            all += (try? await svc.readDTCs(kind: .permanent)) ?? []
            dtcs = all
            lastDTCRead = Date()
            monitor = (try? await svc.monitorStatus()) ?? monitor
            updatePollPlan()
        } catch {
            alertMessage = "Не вдалося прочитати помилки: " + Self.describe(error)
        }
    }

    func clearDTCs() async {
        guard let svc = service else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await svc.clearDTCs()
            try? await Task.sleep(nanoseconds: 800_000_000)
            await readDTCs()
            live.reset()
        } catch {
            alertMessage = "Помилки не стерто: " + Self.describe(error)
        }
    }

    /// Унікальні коди (для екрана «Норма vs зараз»).
    var uniqueCodes: [String] {
        var seen = Set<String>()
        return dtcs.map(\.code).filter { seen.insert($0).inserted }
    }

    // MARK: Опитування поточних даних

    /// Перерахувати список параметрів для опитування (при зміні екрана, вибору параметрів тощо).
    func updatePollPlan() {
        var pids: [UInt8]
        var interval: UInt64 = 30_000_000
        switch screen {
        case .live:
            pids = livePaused ? [] : selectedPIDs
        case .norm:
            pids = Array(NormRules.requiredPIDs(for: uniqueCodes)).sorted()
        case .overview:
            pids = [0x0C, 0x05, 0x42]
            interval = 400_000_000
        default:
            // Інші екрани живих даних не показують — лише зрідка перевіряємо зв'язок
            pids = [0x0C]
            interval = 1_500_000_000
        }
        if let s = service { pids = pids.filter { s.isSupported($0) } }
        if isDemo { interval = max(interval, 120_000_000) }
        pollPlan.set(pids: pids, interval: interval)
    }

    /// Опитування йде у фоні й не займає головний потік інтерфейсу.
    private func startPolling() {
        pollTask?.cancel()
        guard let svc = service else { return }
        let plan = pollPlan
        let live = self.live
        pollTask = Task.detached(priority: .utility) { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let (pids, interval) = plan.get()
                if pids.isEmpty {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                for pid in pids {
                    if Task.isCancelled { return }
                    guard let def = PIDTable.definition(pid) else { continue }
                    do {
                        if let v = try await svc.read(def) { live.record(pid, v) }
                        failures = 0
                    } catch {
                        failures += 1
                    }
                    if failures >= 6 {
                        await self?.handleDrop("Адаптер перестав відповідати. Перевірте підключення і запалювання.")
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func resetHistory() { live.reset() }

    // MARK: Пакети марок

    func importPack(url: URL) {
        do {
            let p = try database.importPack(from: url)
            packs = database.packs
            alertMessage = "Пакет «\(p.title)» завантажено: \(p.codes.count) кодів."
        } catch {
            alertMessage = Self.describe(error)
        }
    }

    func removePack(_ p: BrandPack) {
        database.removePack(p)
        packs = database.packs
    }

    /// Завантажити список доступних пакетів з інтернету.
    func loadCatalog() async {
        guard catalogState != .loading else { return }
        catalogState = .loading
        do {
            var req = URLRequest(url: PackCatalog.indexURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 12
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            catalog = try JSONDecoder().decode(PackCatalog.self, from: data).packs.sorted { $0.brand < $1.brand }
            catalogState = .loaded
        } catch {
            catalogState = .failed("Не вдалося завантажити каталог. Перевірте інтернет. Якщо Мак підключений до Wi‑Fi адаптера — інтернету в цей час немає.")
        }
    }

    enum PackStatus { case notInstalled, installed, updateAvailable }

    func status(of item: PackCatalog.Item) -> PackStatus {
        guard let local = database.installedPack(id: item.id) else { return .notInstalled }
        return PackCatalog.isNewer(item.version, than: local.version) ? .updateAvailable : .installed
    }

    /// Пакет з каталогу, який підходить до поточного авто, але ще не встановлений.
    var suggestedPack: PackCatalog.Item? {
        catalog.first { $0.applies(toBrand: brand) && status(of: $0) != .installed }
    }

    func install(_ item: PackCatalog.Item) async {
        installingPackID = item.id
        defer { installingPackID = nil }
        do {
            var req = URLRequest(url: PackCatalog.fileURL(item))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try database.importPack(data: data)
            packs = database.packs
        } catch {
            alertMessage = "Не вдалося завантажити пакет «\(item.title)». Перевірте інтернет і спробуйте ще раз."
        }
    }

    // MARK: Звіт

    func reportText() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "uk_UA")
        df.dateStyle = .long
        df.timeStyle = .short
        var s = "ЗВІТ ДІАГНОСТИКИ AutoScan\n\(df.string(from: Date()))\n\n"
        s += "АВТО\n"
        if let d = demoScenario { s += "ДЕМО-РЕЖИМ: \(d.car), \(d.engine), \(d.year)\n" }
        if let v = vin {
            s += "VIN: \(v.vin)\n"
            if let m = v.manufacturer { s += "Марка: \(m)\n" }
            if let y = v.modelYear { s += "Модельний рік: \(y)\n" }
            if let c = v.country { s += "Країна: \(c)\n" }
        } else {
            s += "VIN: не отримано\n"
        }
        s += "Адаптер: \(adapterName)\nПротокол: \(connInfo.protocolName)\n\n"
        if let m = monitor {
            s += "Лампа Check Engine: \(m.milOn ? "горить" : "не горить")\n"
            s += "Готовність систем: \(m.completeCount) з \(m.monitors.count)\n"
            for mon in m.monitors { s += "  • \(mon.name): \(mon.complete ? "готово" : "не завершено")\n" }
            s += "\n"
        }
        let ctx = normContext(live)
        s += "ПОМИЛКИ (\(dtcs.count))\n"
        if dtcs.isEmpty { s += "Помилок не знайдено.\n" }
        for d in dtcs {
            let e = entry(for: d)
            s += "\n\(d.code) — \(e.entry.title) [\(d.kind.title)]\n"
            s += "\(e.entry.details)\n"
            s += "Серйозність: \(e.entry.severityTitle)\n"
            s += "Можливі причини:\n"
            for (i, c) in e.entry.causes.enumerated() { s += "  \(i + 1). \(c)\n" }
            let checks = self.checks(for: d.code)
            if !checks.isEmpty {
                s += "Норма vs зараз:\n"
                for ch in checks {
                    let r = ch.evaluate(ctx)
                    s += "  • \(ch.title): \(r.actualText) — \(r.verdict.title). Норма: \(ch.expected)\n"
                }
            }
        }
        return s
    }
}

/// Потокобезпечний «план» опитування для фонової задачі.
final class PollPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [UInt8] = []
    private var interval: UInt64 = 30_000_000

    func set(pids: [UInt8], interval: UInt64) {
        lock.lock(); self.pids = pids; self.interval = interval; lock.unlock()
    }

    func get() -> ([UInt8], UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (pids, interval)
    }
}
#endif
