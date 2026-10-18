#if os(macOS)
import Foundation
import SwiftUI
import AutoScanCore

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case overview, faults, live, norm, report, retro, packs, log
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Огляд"
        case .faults: return "Помилки"
        case .live: return "Живі дані"
        case .norm: return "Норма vs зараз"
        case .report: return "Звіт клієнту"
        case .retro: return "Старі авто"
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
        case .report: return "doc.richtext"
        case .retro: return "clock.arrow.circlepath"
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
    /// Модель, двигун, кузов тощо — з онлайн-бази VIN або з демо-авто.
    @Published private(set) var details: VehicleDetails?
    @Published private(set) var isLookingUpVIN = false
    /// Тип палива і стандарт OBD — повідомляє саме авто.
    @Published private(set) var fuelFromCar: String?
    @Published private(set) var obdStandard: String?
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
                // ~7 разів на секунду: плавно, але без зайвого навантаження
                try? await Task.sleep(nanoseconds: 150_000_000)
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
        vin = nil; monitor = nil; dtcs = []; details = nil; fuelFromCar = nil; obdStandard = nil

        // Різні сканери налаштовані по-різному, тому пробуємо кілька варіантів по черзі:
        // для USB — різні швидкості порту, для Wi‑Fi — найпоширеніші адреси.
        typealias Attempt = (label: String, make: () -> OBDTransport?)
        var attempts: [Attempt] = []
        switch kind {
        case .demo:
            attempts = [("", { () -> OBDTransport? in DemoTransport(scenario: demo) })]
        case .usb:
            let bauds = baud > 0 ? [baud] : [38400, 115200, 9600, 230400, 500000]
            attempts = bauds.map { b -> Attempt in ("швидкість \(b)", { () -> OBDTransport? in SerialTransport(path: serialPath, baudRate: b) }) }
        case .wifi:
            var endpoints: [(String, UInt16)] = [(host, port)]
            for e in [("192.168.0.10", UInt16(35000)), ("192.168.1.10", 35000), ("192.168.0.10", 23),
                      ("192.168.0.123", 35000), ("192.168.1.5", 35000)]
            where !endpoints.contains(where: { $0.0 == e.0 && $0.1 == e.1 }) {
                endpoints.append(e)
            }
            attempts = endpoints.map { e -> Attempt in ("адреса \(e.0):\(e.1)", { () -> OBDTransport? in TCPTransport(host: e.0, port: e.1) }) }
        case .bluetooth:
            attempts = [("", { () -> OBDTransport? in
                guard let d = bleDevice else { return nil }
                return BLETransport(deviceID: d.id, deviceName: d.name)
            })]
        }
        let multi = attempts.count > 1
        let logStore = self.logStore

        Task {
            var lastError: Error = AdapterError.notConnected
            for (i, attempt) in attempts.enumerated() {
                guard let t = attempt.make() else { break }
                if multi {
                    self.connection = .connecting("Пробую \(attempt.label) (\(i + 1) з \(attempts.count))…")
                }
                let session = ELM327Session(transport: t)
                session.onLog = { line in logStore.record(line) }
                t.onDisconnect = { [weak self] reason in
                    Task { @MainActor in self?.handleDrop(reason) }
                }
                let svc = OBDService(session: session)
                do {
                    try await t.open()
                    if multi {
                        // Швидка перевірка: чи відповідає сканер з цими налаштуваннями
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
            if kind == .usb, multi, (lastError as? AdapterError) == .timeout {
                message = "Сканер не відповідає. Перевірте, що вибрано правильний пристрій і сканер вставлений у машину (на ньому має світитися лампочка)."
            }
            if kind == .wifi, multi, !(lastError is AdapterError && (lastError as? AdapterError) == .unableToConnect) {
                message = "Не вдалося знайти Wi‑Fi сканер. Перевірте, що Мак підключений до Wi‑Fi мережі сканера, а сканер вставлений у машину. Якщо в інструкції сканера вказана своя адреса — введіть її в «Додаткових налаштуваннях»."
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

    /// Завершити діагностику: відключитися і очистити все про попереднє авто,
    /// щоб одразу почати нову — без перезапуску програми.
    func finishSession(startNew: Bool = false) {
        disconnect()
        dtcs = []
        vin = nil; monitor = nil; details = nil
        fuelFromCar = nil; obdStandard = nil
        lastDTCRead = nil
        connInfo = ConnectionInfo()
        adapterName = ""
        logStore.clear()
        screen = .overview
        if startNew { showConnectSheet = true }
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
        fuelFromCar = await svc.readByte(0x51).flatMap(VehicleInfoCodes.fuelType)
        obdStandard = await svc.readByte(0x1C).flatMap(VehicleInfoCodes.obdStandard)
        if let demo = demoScenario {
            details = demo.details
        } else if let v = vin?.vin {
            await lookupVIN(v)
        } else {
            details = nil
        }
    }

    /// Шукає модель, двигун і комплектацію за VIN у безкоштовній онлайн-базі.
    func lookupVIN(_ vin: String) async {
        guard let url = NHTSADecoder.url(vin: vin) else { return }
        isLookingUpVIN = true
        defer { isLookingUpVIN = false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        details = NHTSADecoder.parse(data)
    }

    /// Тип палива: з бази VIN, від авто або за статусом моніторів (дизель / бензин).
    var fuelText: String? {
        details?.fuel ?? fuelFromCar ?? monitor.map { $0.isDiesel ? "дизель" : "бензин" }
    }

    /// Чи є турбіна: з бази VIN / демо, або за тиском наддуву, який бачили датчики.
    func turboText(_ live: LiveStore) -> (String, String)? {
        if let t = details?.turbo { return (t ? "так" : "ні (атмосферний)", details?.source ?? "") }
        if EngineEstimator.turbo(mapHistory: live.history[0x0B] ?? [], baro: live.values[0x33], diesel: monitor?.isDiesel ?? false) == true {
            return ("так", "виявлено тиск наддуву за датчиком MAP")
        }
        if monitor?.isDiesel == true { return ("ймовірно так", "майже всі сучасні дизелі з турбіною") }
        return nil
    }

    /// Робочий об'єм: з бази VIN / демо, або приблизна оцінка за датчиками на холостому ходу.
    func displacementText(_ live: LiveStore) -> (String, String)? {
        if let d = details?.displacementL {
            return (String(format: "%.1f л", d).replacingOccurrences(of: ".", with: ","), details?.source ?? "")
        }
        let v = live.values
        if let maf = v[0x10], let map = v[0x0B], let rpm = v[0x0C], let iat = v[0x0F],
           (v[0x0D] ?? 0) < 3,
           let est = EngineEstimator.displacement(mafGs: maf, mapKPa: map, rpm: rpm, intakeC: iat, diesel: monitor?.isDiesel ?? false) {
            return ("≈ " + String(format: "%.1f л", est).replacingOccurrences(of: ".", with: ","), "оцінка за витратою повітря на холостому (±20 %)")
        }
        return nil
    }

    // MARK: Демо-педаль газу

    /// Педаль газу в демо-режимі: 0…1 — натиснута, nil — відпущена.
    func demoPedal(_ value: Double?) {
        (transport as? DemoTransport)?.setPedal(value)
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
            pids = [0x0C, 0x05, 0x42, 0x04, 0x06, 0x07, 0x10, 0x0B, 0x0F, 0x11, 0x0D, 0x5C, 0xF0]
            interval = 300_000_000
        case .report:
            // Для знімка стану потрібні основні показники і сигнали для «норма vs зараз»
            pids = Array(Set([0x0C, 0x05, 0x42, 0x07, 0x06, 0x10, 0x0B, 0x0F, 0x23])
                .union(NormRules.requiredPIDs(for: uniqueCodes))).sorted()
            interval = 300_000_000
        default:
            // Інші екрани живих даних не показують — лише зрідка перевіряємо зв'язок
            pids = [0x0C]
            interval = 1_500_000_000
        }
        // Сумарна корекція рахується з короткої і довгої — їх теж треба опитувати
        if pids.contains(0xF1) {
            for p in [UInt8(0x06), 0x07] where !pids.contains(p) { pids.append(p) }
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
            var cycle = 0
            var multi = svc.multiPID
            while !Task.isCancelled {
                let (pids, interval) = plan.get()
                if pids.isEmpty {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                cycle += 1
                let defs = pids.compactMap { PIDTable.definition($0) }
                let real = defs.filter { !$0.isVirtual }
                let groupable = real.filter(\.multiSafe)
                let single = real.filter { !$0.multiSafe }

                // Групи запитів: у швидкому режимі прості параметри по 6 за раз, складні — по одному
                let groups: [[PIDDefinition]] = multi
                    ? stride(from: 0, to: groupable.count, by: 6).map { Array(groupable[$0..<min($0 + 6, groupable.count)]) } + single.map { [$0] }
                    : real.map { [$0] }
                for group in groups {
                    if Task.isCancelled { return }
                    do {
                        if group.count > 1 {
                            let got = try await svc.readMany(group)
                            if got.isEmpty {
                                // Сканер не впорався з груповим запитом — переходимо на поодинокі
                                multi = false
                                for def in group { if let v = try await svc.read(def) { live.record(def.pid, v) } }
                            } else {
                                for (pid, v) in got { live.record(pid, v) }
                            }
                        } else if let def = group.first, let v = try await svc.read(def) {
                            live.record(def.pid, v)
                        }
                        failures = 0
                    } catch {
                        failures += 1
                    }
                    if failures >= 6 {
                        await self?.handleDrop("Адаптер перестав відповідати. Перевірте підключення і запалювання.")
                        return
                    }
                }

                // Віртуальні параметри
                if pids.contains(0xF0), cycle % 4 == 1, let v = try? await svc.adapterVoltage() {
                    live.record(0xF0, v)
                }
                if pids.contains(0xF1), let a = live.latest(0x06), let b = live.latest(0x07) {
                    live.record(0xF1, a + b)
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
