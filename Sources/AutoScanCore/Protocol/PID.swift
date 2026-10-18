import Foundation

public enum PIDCategory: String, CaseIterable, Sendable {
    case engine = "Двигун"
    case fuel = "Паливо"
    case air = "Повітря і наддув"
    case exhaust = "Вихлоп і лямбда"
    case electric = "Електрика"
    case other = "Інше"
}

/// Опис параметра поточних даних (режим 01).
public struct PIDDefinition: Identifiable, Hashable, @unchecked Sendable {
    public let pid: UInt8
    public let name: String
    public let shortName: String
    public let unit: String
    /// Діапазон для шкали графіка.
    public let scaleMin: Double
    public let scaleMax: Double
    public let decimals: Int
    public let category: PIDCategory
    let bytes: Int
    let formula: ([UInt8]) -> Double

    public var id: UInt8 { pid }
    public var hexCode: String { String(format: "01%02X", pid) }

    public static func == (l: PIDDefinition, r: PIDDefinition) -> Bool { l.pid == r.pid }
    public func hash(into h: inout Hasher) { h.combine(pid) }

    public func decode(_ data: [UInt8]) -> Double? {
        guard data.count >= bytes else { return nil }
        return formula(data)
    }

    public func format(_ value: Double) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

private func ab(_ d: [UInt8]) -> Double { Double(Int(d[0]) * 256 + Int(d[1])) }
private func pct(_ d: [UInt8]) -> Double { Double(d[0]) * 100.0 / 255.0 }
private func temp(_ d: [UInt8]) -> Double { Double(d[0]) - 40 }
private func trim(_ d: [UInt8]) -> Double { (Double(d[0]) - 128) * 100.0 / 128.0 }

public enum PIDTable {

    public static let all: [PIDDefinition] = [
        .init(pid: 0x0C, name: "Оберти двигуна", shortName: "Оберти", unit: "об/хв", scaleMin: 0, scaleMax: 7000, decimals: 0, category: .engine, bytes: 2, formula: { ab($0) / 4 }),
        .init(pid: 0x05, name: "Температура охолоджувальної рідини", shortName: "Т° ОР", unit: "°C", scaleMin: -40, scaleMax: 130, decimals: 0, category: .engine, bytes: 1, formula: temp),
        .init(pid: 0x04, name: "Навантаження двигуна (розрахункове)", shortName: "Навантаження", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .engine, bytes: 1, formula: pct),
        .init(pid: 0x43, name: "Абсолютне навантаження", shortName: "Абс. навантаж.", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .engine, bytes: 2, formula: { ab($0) * 100 / 255 }),
        .init(pid: 0x0E, name: "Кут випередження запалювання", shortName: "УОЗ", unit: "°", scaleMin: -20, scaleMax: 50, decimals: 1, category: .engine, bytes: 1, formula: { Double($0[0]) / 2 - 64 }),
        .init(pid: 0x0D, name: "Швидкість авто", shortName: "Швидкість", unit: "км/год", scaleMin: 0, scaleMax: 220, decimals: 0, category: .engine, bytes: 1, formula: { Double($0[0]) }),
        .init(pid: 0x5C, name: "Температура масла", shortName: "Т° масла", unit: "°C", scaleMin: -40, scaleMax: 150, decimals: 0, category: .engine, bytes: 1, formula: temp),
        .init(pid: 0x1F, name: "Час роботи після запуску", shortName: "Час роботи", unit: "с", scaleMin: 0, scaleMax: 3600, decimals: 0, category: .engine, bytes: 2, formula: ab),

        .init(pid: 0x06, name: "Коротка корекція палива, ряд 1", shortName: "Корекція кор. 1", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 1, formula: trim),
        .init(pid: 0x07, name: "Довга корекція палива, ряд 1", shortName: "Корекція довга 1", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 1, formula: trim),
        .init(pid: 0x08, name: "Коротка корекція палива, ряд 2", shortName: "Корекція кор. 2", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 1, formula: trim),
        .init(pid: 0x09, name: "Довга корекція палива, ряд 2", shortName: "Корекція довга 2", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 1, formula: trim),
        .init(pid: 0x0A, name: "Тиск палива", shortName: "Тиск палива", unit: "кПа", scaleMin: 0, scaleMax: 765, decimals: 0, category: .fuel, bytes: 1, formula: { Double($0[0]) * 3 }),
        .init(pid: 0x23, name: "Тиск у паливній рампі (дизель / пряме вприскування)", shortName: "Тиск у рампі", unit: "бар", scaleMin: 0, scaleMax: 2000, decimals: 0, category: .fuel, bytes: 2, formula: { ab($0) * 0.1 }),
        .init(pid: 0x22, name: "Тиск у рампі відносно колектора", shortName: "Тиск рампи (відн.)", unit: "кПа", scaleMin: 0, scaleMax: 600, decimals: 0, category: .fuel, bytes: 2, formula: { ab($0) * 0.079 }),
        .init(pid: 0x2F, name: "Рівень палива в баку", shortName: "Рівень палива", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .fuel, bytes: 1, formula: pct),
        .init(pid: 0x5E, name: "Миттєва витрата палива", shortName: "Витрата", unit: "л/год", scaleMin: 0, scaleMax: 30, decimals: 1, category: .fuel, bytes: 2, formula: { ab($0) / 20 }),
        .init(pid: 0x44, name: "Задана лямбда (склад суміші)", shortName: "Задана λ", unit: "λ", scaleMin: 0.7, scaleMax: 1.3, decimals: 3, category: .fuel, bytes: 2, formula: { ab($0) * 2 / 65536 }),

        .init(pid: 0x10, name: "Масова витрата повітря (ДМРВ)", shortName: "ДМРВ", unit: "г/с", scaleMin: 0, scaleMax: 200, decimals: 1, category: .air, bytes: 2, formula: { ab($0) / 100 }),
        .init(pid: 0x0B, name: "Абсолютний тиск у впускному колекторі (MAP)", shortName: "Тиск MAP", unit: "кПа", scaleMin: 0, scaleMax: 255, decimals: 0, category: .air, bytes: 1, formula: { Double($0[0]) }),
        .init(pid: 0x33, name: "Атмосферний тиск", shortName: "Атм. тиск", unit: "кПа", scaleMin: 70, scaleMax: 110, decimals: 0, category: .air, bytes: 1, formula: { Double($0[0]) }),
        .init(pid: 0x0F, name: "Температура повітря на впуску", shortName: "Т° впуску", unit: "°C", scaleMin: -40, scaleMax: 100, decimals: 0, category: .air, bytes: 1, formula: temp),
        .init(pid: 0x46, name: "Температура повітря назовні", shortName: "Т° назовні", unit: "°C", scaleMin: -40, scaleMax: 60, decimals: 0, category: .air, bytes: 1, formula: temp),
        .init(pid: 0x11, name: "Положення дросельної заслінки", shortName: "Дросель", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x45, name: "Відносне положення дроселя", shortName: "Дросель відн.", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x4C, name: "Задане положення дроселя", shortName: "Дросель заданий", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x49, name: "Положення педалі газу", shortName: "Педаль газу", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x2C, name: "Заданий ступінь відкриття EGR", shortName: "EGR задано", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x2D, name: "Похибка EGR", shortName: "EGR похибка", unit: "%", scaleMin: -100, scaleMax: 100, decimals: 0, category: .air, bytes: 1, formula: trim),

        .init(pid: 0x14, name: "Лямбда-зонд 1 (ряд 1, до каталізатора)", shortName: "Лямбда B1S1", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x15, name: "Лямбда-зонд 2 (ряд 1, після каталізатора)", shortName: "Лямбда B1S2", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x18, name: "Лямбда-зонд 1 (ряд 2, до каталізатора)", shortName: "Лямбда B2S1", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x19, name: "Лямбда-зонд 2 (ряд 2, після каталізатора)", shortName: "Лямбда B2S2", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x3C, name: "Температура каталізатора (ряд 1)", shortName: "Т° каталізатора", unit: "°C", scaleMin: 0, scaleMax: 1000, decimals: 0, category: .exhaust, bytes: 2, formula: { ab($0) / 10 - 40 }),

        .init(pid: 0x42, name: "Напруга бортової мережі (на блоці)", shortName: "Напруга", unit: "В", scaleMin: 10, scaleMax: 16, decimals: 2, category: .electric, bytes: 2, formula: { ab($0) / 1000 }),

        .init(pid: 0x21, name: "Пробіг з горящою лампою Check Engine", shortName: "Пробіг з помилкою", unit: "км", scaleMin: 0, scaleMax: 10000, decimals: 0, category: .other, bytes: 2, formula: ab),
        .init(pid: 0x31, name: "Пробіг після стирання помилок", shortName: "Пробіг після стирання", unit: "км", scaleMin: 0, scaleMax: 10000, decimals: 0, category: .other, bytes: 2, formula: ab),
    ]

    public static let byPID: [UInt8: PIDDefinition] = {
        var d: [UInt8: PIDDefinition] = [:]
        for p in all { d[p.pid] = p }
        return d
    }()

    public static func definition(_ pid: UInt8) -> PIDDefinition? { byPID[pid] }

    /// Набір за замовчуванням для екрана «Живі дані».
    public static let defaultSelection: [UInt8] = [0x0C, 0x05, 0x04, 0x10, 0x0B, 0x06, 0x07, 0x14, 0x11, 0x42]
}
