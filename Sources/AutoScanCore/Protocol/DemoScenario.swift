import Foundation

/// Як поводиться лямбда-зонд у демо-авто.
public enum DemoO2: Sendable {
    case normal      // перемикається 0,1–0,9 В
    case lean        // «сидить» низько
    case rich        // «сидить» високо
    case absent      // широкосмуговий / дизель — через OBD2 не видно
}

public enum DemoDownstreamO2: Sendable {
    case steady      // каталізатор працює
    case mirror      // повторює перший зонд — каталізатор зношений
}

/// Параметри «двигуна» демо-авто.
public struct DemoEngine: Sendable {
    var idleRPM: Double = 780
    var rpmJitter: Double = 8
    var driveRPM: Double = 3200
    var coolantStart: Double = 76
    var coolantTarget: Double = 91
    var coolantOverride: Double? = nil
    var intakeOverride: Double? = nil
    var stft: Double = 0.8
    var ltft: Double = 1.6
    var mapIdle: Double = 33
    /// Абсолютний тиск у колекторі під повним навантаженням (кПа); для атмосферних ~97.
    var mapPeak: Double = 97
    var mafIdle: Double = 3.0
    var mafDrive: Double = 55
    var o2: DemoO2 = .normal
    var o2Down: DemoDownstreamO2 = .steady
    var voltage: Double = 14.1
    var railIdle: Double? = nil
    var railDrive: Double = 1100
    var egrError: Double? = nil
    var fuelLevel: Double = 46
}

/// Готовий «автомобіль» для демо-режиму: марка, протокол, несправності.
public struct DemoScenario: Identifiable, Sendable {
    public let id: String
    public let car: String
    public let engine: String
    public let year: Int
    /// Що з машиною (коротко, для вибору в списку).
    public let summary: String
    let vin: String?
    /// Номер протоколу ELM327: «6» — CAN 11/500, «5» — KWP2000, «3» — ISO 9141.
    let protocolNumber: String
    public let isDiesel: Bool
    let stored: [String]
    let pending: [String]
    let permanent: [String]
    let supportsPermanent: Bool
    /// Байт C статусу моніторів (які системи самоперевірки є).
    let monitorsC: UInt8
    /// Байт D — які з них не завершені, коли є несправності.
    let monitorsIncomplete: UInt8
    let pids: Set<UInt8>
    let model: DemoEngine
    /// Імітує дешевий сканер, який не знаходить протокол автоматично.
    var failsAutoSearch: Bool = false
    // Паспортні дані двигуна і кузова (для картки авто в демо)
    public var displacement: Double = 0
    public var cylinders: Int = 4
    public var turbo: Bool = false
    public var powerKW: Int = 0
    public var body: String = ""
    public var transmission: String = ""

    func spec(_ l: Double, cyl: Int = 4, turbo: Bool, kw: Int, body: String, gearbox: String) -> DemoScenario {
        var c = self
        c.displacement = l; c.cylinders = cyl; c.turbo = turbo; c.powerKW = kw; c.body = body; c.transmission = gearbox
        return c
    }

    /// Картка авто для демо (те, що для справжнього авто приходить з онлайн-бази VIN).
    public var details: VehicleDetails {
        var d = VehicleDetails(source: "демо-авто")
        let parts = car.split(separator: " ", maxSplits: 1).map(String.init)
        d.make = parts.first
        d.model = parts.count > 1 ? parts[1] : nil
        d.year = year
        d.displacementL = displacement > 0 ? displacement : nil
        d.cylinders = cylinders
        d.powerKW = powerKW > 0 ? powerKW : nil
        d.fuel = isDiesel ? "дизель" : "бензин"
        d.turbo = turbo
        d.body = body.isEmpty ? nil : body
        d.transmission = transmission.isEmpty ? nil : transmission
        d.drive = id == "bmw" || id == "mercedes" ? "задній" : "передній"
        return d
    }

    public var isCAN: Bool { ["6", "7", "8", "9"].contains(protocolNumber) }
    public var faultCount: Int { Set(stored + pending + permanent).count }

    // Набори параметрів, які «підтримує» авто
    static let petrolPIDs: Set<UInt8> = [0x01, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11,
                                         0x14, 0x15, 0x1F, 0x21, 0x2F, 0x31, 0x33, 0x42, 0x43, 0x44, 0x45, 0x46, 0x49,
                                         0x24, 0x2E, 0x30, 0x47, 0x4A, 0x4D, 0x4E, 0x5A, 0x61, 0x62, 0x63,
                                         0x55, 0x56, 0x67, 0x7F, 0x8E, 0x1C, 0x51]
    static let oldPetrolPIDs: Set<UInt8> = [0x01, 0x1C, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x14, 0x15]
    static let dieselPIDs: Set<UInt8> = [0x01, 0x04, 0x05, 0x0B, 0x0C, 0x0D, 0x0F, 0x10, 0x1F, 0x21, 0x23, 0x2C,
                                         0x2D, 0x2F, 0x31, 0x33, 0x42, 0x43, 0x46, 0x49, 0x5C,
                                         0x30, 0x4D, 0x4E, 0x61, 0x62, 0x63,
                                         0x67, 0x6F, 0x73, 0x74, 0x77, 0x78, 0x7A, 0x7C, 0x7F, 0x8E, 0x1C, 0x51]

    public static let all: [DemoScenario] = [
        DemoScenario(
            id: "passat", car: "Volkswagen Passat B7", engine: "1.8 TSI · бензин · турбо", year: 2014,
            summary: "Бідна суміш, слабкий наддув, пропуски в 1-му циліндрі",
            vin: "WVWZZZ3CZEE123456", protocolNumber: "6", isDiesel: false,
            stored: ["P0171", "P0299"], pending: ["P0301"], permanent: [], supportsPermanent: true,
            monitorsC: 0x65, monitorsIncomplete: 0x04, pids: petrolPIDs.union([0x5C, 0x6F, 0x74, 0x77]),
            model: DemoEngine(idleRPM: 790, rpmJitter: 75, driveRPM: 3400, stft: 6.2, ltft: 17.9,
                              mapPeak: 131, mafIdle: 3.1, mafDrive: 62, o2: .lean)).spec(1.8, turbo: true, kw: 118, body: "седан", gearbox: "робот DSG"),

        DemoScenario(
            id: "camry", car: "Toyota Camry XV50", engine: "2.5 · бензин", year: 2016,
            summary: "Повністю справне авто — так виглядає норма",
            vin: "JTNB11HK0G3123456", protocolNumber: "6", isDiesel: false,
            stored: [], pending: [], permanent: [], supportsPermanent: true,
            monitorsC: 0x65, monitorsIncomplete: 0x00, pids: petrolPIDs.union([0xA6]),
            model: DemoEngine(idleRPM: 690, rpmJitter: 6, driveRPM: 2900, stft: -0.8, ltft: 2.3,
                              mapIdle: 30, mafIdle: 3.4, mafDrive: 58)).spec(2.5, turbo: false, kw: 133, body: "седан", gearbox: "автомат"),

        DemoScenario(
            id: "megane", car: "Renault Mégane III", engine: "1.5 dCi · дизель", year: 2012,
            summary: "Низький тиск палива, забитий сажовий фільтр, слабкий EGR",
            vin: "VF1BZ1B0HC6123456", protocolNumber: "6", isDiesel: true,
            stored: ["P0087", "P2463"], pending: ["P0401"], permanent: [], supportsPermanent: true,
            monitorsC: 0xEB, monitorsIncomplete: 0xC0, pids: dieselPIDs,
            model: DemoEngine(idleRPM: 820, rpmJitter: 10, driveRPM: 2600, mapIdle: 101, mapPeak: 205,
                              mafIdle: 9.5, mafDrive: 48, o2: .absent, voltage: 14.3,
                              railIdle: 175, railDrive: 900, egrError: -23, fuelLevel: 31)).spec(1.5, turbo: true, kw: 81, body: "хетчбек", gearbox: "механіка"),

        DemoScenario(
            id: "astra", car: "Opel Astra G", engine: "1.6 · бензин", year: 2003,
            summary: "Зношений каталізатор і термостат; старий протокол, без VIN, капризний клон-сканер",
            vin: nil, protocolNumber: "5", isDiesel: false,
            stored: ["P0420", "P0128"], pending: [], permanent: [], supportsPermanent: false,
            monitorsC: 0x25, monitorsIncomplete: 0x01, pids: oldPetrolPIDs,
            model: DemoEngine(idleRPM: 850, rpmJitter: 15, driveRPM: 3000, coolantStart: 67, coolantTarget: 71,
                              stft: 1.5, ltft: 3.1, mapIdle: 36, o2Down: .mirror, voltage: 13.9),
            failsAutoSearch: true).spec(1.6, turbo: false, kw: 74, body: "хетчбек", gearbox: "механіка"),

        DemoScenario(
            id: "bmw", car: "BMW 3 E90 320i", engine: "2.0 · бензин", year: 2007,
            summary: "Збиті фази ГРМ (ланцюг), сигнал розподільного вала",
            vin: "WBAVA31077KX12345", protocolNumber: "6", isDiesel: false,
            stored: ["P0016"], pending: ["P0340"], permanent: [], supportsPermanent: false,
            monitorsC: 0x65, monitorsIncomplete: 0x00, pids: petrolPIDs.subtracting([0x44]),
            model: DemoEngine(idleRPM: 720, rpmJitter: 80, driveRPM: 3100, stft: 3.5, ltft: 7.8,
                              mapIdle: 41, mafIdle: 3.9, mafDrive: 60)).spec(2.0, turbo: false, kw: 110, body: "седан", gearbox: "механіка"),

        DemoScenario(
            id: "octavia", car: "Škoda Octavia A5", engine: "1.6 MPI · бензин", year: 2010,
            summary: "Високі оберти холостого ходу, генератор не заряджає",
            vin: "TMBBA61Z0A2123456", protocolNumber: "6", isDiesel: false,
            stored: ["P0507", "P0562"], pending: [], permanent: ["P0562"], supportsPermanent: true,
            monitorsC: 0x65, monitorsIncomplete: 0x04, pids: petrolPIDs,
            model: DemoEngine(idleRPM: 1180, rpmJitter: 12, driveRPM: 3000, stft: 2.0, ltft: 4.0,
                              mapIdle: 44, mafIdle: 4.6, mafDrive: 52, voltage: 12.6)).spec(1.6, turbo: false, kw: 75, body: "ліфтбек", gearbox: "механіка"),

        DemoScenario(
            id: "tucson", car: "Hyundai Tucson", engine: "2.0 · бензин", year: 2011,
            summary: "Обриви датчиків температури рідини і повітря",
            vin: "KMHJU81BDBU123456", protocolNumber: "6", isDiesel: false,
            stored: ["P0118", "P0113"], pending: [], permanent: [], supportsPermanent: true,
            monitorsC: 0x65, monitorsIncomplete: 0x24, pids: petrolPIDs,
            model: DemoEngine(idleRPM: 760, rpmJitter: 10, driveRPM: 2900, coolantOverride: -40,
                              intakeOverride: -40, stft: 1.0, ltft: 5.5, mafIdle: 3.6)).spec(2.0, turbo: false, kw: 120, body: "кросовер", gearbox: "автомат"),

        DemoScenario(
            id: "mercedes", car: "Mercedes-Benz C W204 C220 CDI", engine: "2.1 CDI · дизель", year: 2009,
            summary: "Перенаддув турбіни, забруднений ДМРВ",
            vin: "WDD2040089A123456", protocolNumber: "6", isDiesel: true,
            stored: ["P0234", "P0101"], pending: [], permanent: [], supportsPermanent: false,
            monitorsC: 0xEB, monitorsIncomplete: 0x08, pids: dieselPIDs,
            model: DemoEngine(idleRPM: 760, rpmJitter: 9, driveRPM: 2700, mapIdle: 101, mapPeak: 272,
                              mafIdle: 1.3, mafDrive: 40, o2: .absent, voltage: 14.2,
                              railIdle: 290, railDrive: 1300, egrError: 3, fuelLevel: 63)).spec(2.1, turbo: true, kw: 125, body: "седан", gearbox: "автомат"),
    ]

    public static let `default` = all[0]

    public static func with(id: String) -> DemoScenario {
        all.first { $0.id == id } ?? .default
    }
}
