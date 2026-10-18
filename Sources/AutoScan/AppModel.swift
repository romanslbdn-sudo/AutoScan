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
    @Published var screen: Screen = .overview
    @Published var showConnectSheet = false

    // Підключення
    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var adapterName = ""
    @Published private(set) var connInfo = ConnectionInfo()
    @Published private(set) var isDemo = false

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

    // Живі дані
    @Published private(set) var values: [UInt8: Double] = [:]
    @Published private(set) var history: [UInt8: [Double]] = [:]
    @Published var selectedPIDs: [UInt8] {
        didSet { UserDefaults.standard.set(selectedPIDs.map(Int.init), forKey: "selectedPIDs") }
    }
    @Published var livePaused = false

    // Журнал і повідомлення
    @Published private(set) var log: [AdapterLogLine] = []
    @Published var alertMessage: String?

    let database = DTCDatabase()
    @Published private(set) var packs: [BrandPack] = []

    private var service: OBDService?
    private var transport: OBDTransport?
    private var pollTask: Task<Void, Never>?
    private let historyLimit = 150

    init() {
        if let saved = UserDefaults.standard.array(forKey: "selectedPIDs") as? [Int], !saved.isEmpty {
            selectedPIDs = saved.map { UInt8($0) }
        } else {
            selectedPIDs = PIDTable.defaultSelection
        }
        packs = database.packs
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

    var normContext: NormContext {
        NormContext(current: values, history: history, isDiesel: monitor?.isDiesel ?? false)
    }

    // MARK: Підключення

    func connect(kind: ConnectionKind, serialPath: String = "", baud: Int = 38400,
                 host: String = "192.168.0.10", port: UInt16 = 35000, bleDevice: BLEDevice? = nil) {
        disconnect(silently: true)
        let t: OBDTransport
        switch kind {
        case .demo: t = DemoTransport()
        case .usb: t = SerialTransport(path: serialPath, baudRate: baud)
        case .wifi: t = TCPTransport(host: host, port: port)
        case .bluetooth:
            guard let d = bleDevice else { return }
            t = BLETransport(deviceID: d.id, deviceName: d.name)
        }
        transport = t
        isDemo = kind == .demo
        adapterName = t.displayName
        connection = .connecting("Підключення до адаптера…")
        log.removeAll()

        let session = ELM327Session(transport: t)
        session.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        t.onDisconnect = { [weak self] reason in
            Task { @MainActor in self?.handleDrop(reason) }
        }
        let svc = OBDService(session: session)

        Task {
            do {
                try await t.open()
                try await svc.initialize { [weak self] text in
                    Task { @MainActor in
                        if case .connecting = self?.connection { self?.connection = .connecting(text) }
                    }
                }
                self.service = svc
                self.connInfo = svc.info
                self.connection = .connected
                self.showConnectSheet = false
                await self.readVehicle()
                await self.readDTCs()
                self.startPolling()
            } catch {
                t.close()
                self.transport = nil
                self.service = nil
                self.connection = .failed(Self.describe(error))
            }
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
        }
        values = [:]
        history = [:]
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

    private func appendLog(_ line: AdapterLogLine) {
        log.append(line)
        if log.count > 800 { log.removeFirst(log.count - 800) }
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
            // Один і той самий код може бути і «активним», і «постійним» — показуємо обидва статуси.
            dtcs = all
            lastDTCRead = Date()
            monitor = (try? await svc.monitorStatus()) ?? monitor
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
            history = [:]
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

    private func pidsToPoll() -> [UInt8] {
        switch screen {
        case .live:
            return livePaused ? [] : selectedPIDs
        case .norm:
            return Array(NormRules.requiredPIDs(for: uniqueCodes)).sorted()
        case .overview:
            return [0x0C, 0x05, 0x42, 0x0D]
        default:
            return [0x0C, 0x42]
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, let svc = self.service else { return }
                let pids = self.pidsToPoll().filter { svc.isSupported($0) }
                if pids.isEmpty {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                for pid in pids {
                    if Task.isCancelled { return }
                    guard let def = PIDTable.definition(pid) else { continue }
                    do {
                        let v = try await svc.read(def)
                        failures = 0
                        self.store(pid, v)
                    } catch AdapterError.timeout {
                        failures += 1
                    } catch {
                        failures += 1
                    }
                    if failures >= 6 {
                        self.handleDrop("Адаптер перестав відповідати. Перевірте підключення і запалювання.")
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: self.isDemo ? 120_000_000 : 30_000_000)
            }
        }
    }

    private func store(_ pid: UInt8, _ value: Double?) {
        guard let value else { return }
        values[pid] = value
        var h = history[pid] ?? []
        h.append(value)
        if h.count > historyLimit { h.removeFirst(h.count - historyLimit) }
        history[pid] = h
    }

    func resetHistory() { history = [:] }

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

    // MARK: Звіт

    func reportText() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "uk_UA")
        df.dateStyle = .long
        df.timeStyle = .short
        var s = "ЗВІТ ДІАГНОСТИКИ AutoScan\n\(df.string(from: Date()))\n\n"
        s += "АВТО\n"
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
        s += "ПОМИЛКИ (\(dtcs.count))\n"
        if dtcs.isEmpty { s += "Помилок не знайдено.\n" }
        for d in dtcs {
            let e = entry(for: d)
            s += "\n\(d.code) — \(e.entry.title) [\(d.kind.title)]\n"
            s += "\(e.entry.details)\n"
            s += "Серйозність: \(e.entry.severityTitle)\n"
            s += "Можливі причини:\n"
            for (i, c) in e.entry.causes.enumerated() { s += "  \(i + 1). \(c)\n" }
            let checks = NormRules.checks(for: d.code)
            if !checks.isEmpty {
                s += "Норма vs зараз:\n"
                for ch in checks {
                    let r = ch.evaluate(normContext)
                    s += "  • \(ch.title): \(r.actualText) — \(r.verdict.title). Норма: \(ch.expected)\n"
                }
            }
        }
        return s
    }
}
#endif
