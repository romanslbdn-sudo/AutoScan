#if os(macOS)
import Foundation
import CoreBluetooth
import AutoScanCore

/// Знайдений Bluetooth LE пристрій.
struct BLEDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    var rssi: Int
    /// Схоже на OBD-адаптер за назвою.
    var looksLikeOBD: Bool {
        let n = name.lowercased()
        return ["obd", "elm", "vgate", "icar", "veepeak", "obdlink", "v-link", "vlink", "konnwei", "carista", "scan", "ios-vlink"]
            .contains { n.contains($0) }
    }
}

/// Керує Bluetooth: пошук пристроїв і підключення до адаптера.
final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate {
    static let shared = BLEManager()

    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var stateText = ""

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connectContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var pendingConnectID: UUID?
    fileprivate var activeTransport: BLETransport?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        devices = []
        guard central.state == .poweredOn else {
            isScanning = true // почнемо, щойно Bluetooth увімкнеться
            return
        }
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        isScanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    func peripheral(id: UUID) -> CBPeripheral? { peripherals[id] }

    func connect(_ p: CBPeripheral) async throws -> CBPeripheral {
        await MainActor.run { self.stopScan() }
        return try await withCheckedThrowingContinuation { cont in
            connectContinuation = cont
            pendingConnectID = p.identifier
            DispatchQueue.main.async { self.central.connect(p, options: nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.pendingConnectID == p.identifier, let c = self.connectContinuation else { return }
                self.connectContinuation = nil
                self.pendingConnectID = nil
                self.central.cancelPeripheralConnection(p)
                c.resume(throwing: AdapterError.transport("Не вдалося підключитися до \(p.name ?? "пристрою") за 12 секунд."))
            }
        }
    }

    func disconnect(_ p: CBPeripheral) {
        central.cancelPeripheralConnection(p)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            stateText = ""
            if isScanning { central.scanForPeripherals(withServices: nil, options: nil) }
        case .poweredOff: stateText = "Bluetooth вимкнено. Увімкніть його в налаштуваннях Mac."
        case .unauthorized: stateText = "Програмі не дозволено користуватися Bluetooth. Дозвольте в «Системні параметри → Приватність і безпека → Bluetooth»."
        case .unsupported: stateText = "Цей Mac не підтримує Bluetooth LE."
        default: stateText = "Bluetooth готується…"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        guard let name, !name.isEmpty else { return }
        peripherals[peripheral.identifier] = peripheral
        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[i].rssi = RSSI.intValue
        } else {
            devices.append(BLEDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        }
        devices.sort { ($0.looksLikeOBD ? 1 : 0, $0.rssi) > ($1.looksLikeOBD ? 1 : 0, $1.rssi) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard pendingConnectID == peripheral.identifier, let c = connectContinuation else { return }
        connectContinuation = nil
        pendingConnectID = nil
        c.resume(returning: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard pendingConnectID == peripheral.identifier, let c = connectContinuation else { return }
        connectContinuation = nil
        pendingConnectID = nil
        c.resume(throwing: AdapterError.transport("Не вдалося підключитися: \(error?.localizedDescription ?? "невідома помилка")"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        activeTransport?.peripheralDisconnected(peripheral)
    }
}

/// Адаптер ELM327 через Bluetooth LE (Vgate iCar Pro BLE, Veepeak BLE, OBDLink CX тощо).
final class BLETransport: NSObject, OBDTransport, CBPeripheralDelegate, @unchecked Sendable {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((String) -> Void)?

    let deviceID: UUID
    let deviceName: String
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var pendingServices = 0
    private var closedByUser = false

    var displayName: String { deviceName }

    init(deviceID: UUID, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    // Відомі пари «сервіс → (читання, запис)» популярних адаптерів.
    private static let knownPairs: [(service: String, notify: String, write: String)] = [
        ("FFF0", "FFF1", "FFF2"),
        ("FFE0", "FFE1", "FFE1"),
        ("18F0", "2AF0", "2AF1"),
        ("E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
    ]

    func open() async throws {
        let manager = BLEManager.shared
        guard let p = manager.peripheral(id: deviceID) else {
            throw AdapterError.transport("Пристрій не знайдено. Запустіть пошук ще раз.")
        }
        let connected = try await manager.connect(p)
        peripheral = connected
        await MainActor.run {
            manager.activeTransport = self
            connected.delegate = self
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            setupContinuation = cont
            DispatchQueue.main.async { connected.discoverServices(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.finishSetup(.failure(AdapterError.transport("Пристрій підключився, але не схожий на OBD-адаптер (не знайдено каналу передачі даних).")))
            }
        }
    }

    private func finishSetup(_ r: Result<Void, Error>) {
        guard let c = setupContinuation else { return }
        setupContinuation = nil
        c.resume(with: r)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            finishSetup(.failure(AdapterError.transport("Пристрій не має сервісів Bluetooth.")))
            return
        }
        pendingServices = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServices -= 1
        guard pendingServices <= 0 else { return }
        chooseCharacteristics(peripheral)
    }

    private func chooseCharacteristics(_ peripheral: CBPeripheral) {
        let services = peripheral.services ?? []
        func char(_ service: String, _ uuid: String) -> CBCharacteristic? {
            services.first { $0.uuid == CBUUID(string: service) }?
                .characteristics?.first { $0.uuid == CBUUID(string: uuid) }
        }
        for pair in Self.knownPairs {
            if let n = char(pair.service, pair.notify), let w = char(pair.service, pair.write) {
                notifyChar = n; writeChar = w; break
            }
        }
        if notifyChar == nil || writeChar == nil {
            // Загальний пошук: будь-яка характеристика зі сповіщеннями + будь-яка із записом в одному сервісі
            for s in services {
                let chars = s.characteristics ?? []
                let n = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
                let w = chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
                if let n, let w { notifyChar = n; writeChar = w; break }
            }
        }
        guard let n = notifyChar, writeChar != nil else {
            finishSetup(.failure(AdapterError.transport("Не знайдено каналу передачі даних. Можливо, це не OBD-адаптер.")))
            return
        }
        peripheral.setNotifyValue(true, for: n)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            finishSetup(.failure(AdapterError.transport("Не вдалося підписатися на дані: \(error.localizedDescription)")))
        } else {
            finishSetup(.success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        onReceive?(data)
    }

    func send(_ data: Data) throws {
        guard let p = peripheral, let w = writeChar else { throw AdapterError.notConnected }
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let maxLen = max(20, p.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + maxLen, data.count))
            DispatchQueue.main.async { p.writeValue(chunk, for: w, type: type) }
            offset += maxLen
        }
    }

    func peripheralDisconnected(_ p: CBPeripheral) {
        guard p.identifier == deviceID else { return }
        finishSetup(.failure(AdapterError.transport("Пристрій відключився.")))
        if !closedByUser {
            closedByUser = true
            onDisconnect?("Bluetooth-з'єднання з адаптером обірвалося")
        }
    }

    func close() {
        closedByUser = true
        if let p = peripheral {
            DispatchQueue.main.async { BLEManager.shared.disconnect(p) }
        }
        peripheral = nil
    }
}
#endif
