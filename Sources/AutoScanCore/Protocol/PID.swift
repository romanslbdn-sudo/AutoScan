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
    /// Скільки байтів даних повертає авто на цей параметр (за стандартом).
    public var length: Int { bytes }
    /// Можна запитувати разом з іншими в одному груповому запиті (лише прості параметри).
    public var multiSafe: Bool { !isVirtual && pid < 0x65 && bytes <= 4 }
    /// Мінімальний діапазон графіка — щоб дрібні коливання не виглядали як стрибки.
    public var minChartSpan: Double {
        switch pid {
        case 0x14...0x1B: return 1.0                 // вузькосмугові лямбда-зонди — повний діапазон 0–1 В
        case 0x42, 0xF0: return 1.5                  // напруга
        case 0x05, 0x0F, 0x46, 0x5C, 0x67, 0x77: return 15   // температури
        case 0x06...0x09, 0x55...0x58, 0xF1: return 10        // корекції палива
        case 0x24...0x2B: return 0.2                 // λ
        default: return (scaleMax - scaleMin) * 0.1
        }
    }
    /// Параметр не запитується в авто напряму, а рахується програмою / адаптером.
    public var isVirtual: Bool { pid >= 0xF0 }

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
        .init(pid: 0x05, name: "Температура охолоджувальної рідини", shortName: "Т° антифризу", unit: "°C", scaleMin: -40, scaleMax: 130, decimals: 0, category: .engine, bytes: 1, formula: temp),
        .init(pid: 0x04, name: "Навантаження двигуна (розрахункове)", shortName: "Навантаження двигуна", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .engine, bytes: 1, formula: pct),
        .init(pid: 0x43, name: "Абсолютне навантаження", shortName: "Абс. навантаж.", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .engine, bytes: 2, formula: { ab($0) * 100 / 255 }),
        .init(pid: 0x0E, name: "Кут випередження запалювання", shortName: "Кут запалювання", unit: "°", scaleMin: -20, scaleMax: 50, decimals: 1, category: .engine, bytes: 1, formula: { Double($0[0]) / 2 - 64 }),
        .init(pid: 0x0D, name: "Швидкість авто", shortName: "Швидкість", unit: "км/год", scaleMin: 0, scaleMax: 220, decimals: 0, category: .engine, bytes: 1, formula: { Double($0[0]) }),
        .init(pid: 0x5C, name: "Температура масла", shortName: "Т° масла", unit: "°C", scaleMin: -40, scaleMax: 150, decimals: 0, category: .engine, bytes: 1, formula: temp),
        .init(pid: 0x1F, name: "Час роботи після запуску", shortName: "Час роботи", unit: "с", scaleMin: 0, scaleMax: 3600, decimals: 0, category: .engine, bytes: 2, formula: ab),

        .init(pid: 0x06, name: "Коротка корекція палива, ряд 1", shortName: "Корекція палива миттєва", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 1, formula: trim),
        .init(pid: 0x07, name: "Довга корекція палива, ряд 1", shortName: "Корекція палива довга", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 1, formula: trim),
        .init(pid: 0x08, name: "Коротка корекція палива, ряд 2", shortName: "Корекція миттєва, ряд 2", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 1, formula: trim),
        .init(pid: 0x09, name: "Довга корекція палива, ряд 2", shortName: "Корекція довга, ряд 2", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 1, formula: trim),
        .init(pid: 0x0A, name: "Тиск палива", shortName: "Тиск палива", unit: "кПа", scaleMin: 0, scaleMax: 765, decimals: 0, category: .fuel, bytes: 1, formula: { Double($0[0]) * 3 }),
        .init(pid: 0x23, name: "Тиск у паливній рампі (дизель / пряме вприскування)", shortName: "Тиск у рампі", unit: "бар", scaleMin: 0, scaleMax: 2000, decimals: 0, category: .fuel, bytes: 2, formula: { ab($0) * 0.1 }),
        .init(pid: 0x22, name: "Тиск у рампі відносно колектора", shortName: "Тиск рампи (відн.)", unit: "кПа", scaleMin: 0, scaleMax: 600, decimals: 0, category: .fuel, bytes: 2, formula: { ab($0) * 0.079 }),
        .init(pid: 0x2F, name: "Рівень палива в баку", shortName: "Рівень палива", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .fuel, bytes: 1, formula: pct),
        .init(pid: 0x5E, name: "Миттєва витрата палива", shortName: "Витрата", unit: "л/год", scaleMin: 0, scaleMax: 30, decimals: 1, category: .fuel, bytes: 2, formula: { ab($0) / 20 }),
        .init(pid: 0x44, name: "Задана лямбда (склад суміші)", shortName: "Задана λ", unit: "λ", scaleMin: 0.7, scaleMax: 1.3, decimals: 3, category: .fuel, bytes: 2, formula: { ab($0) * 2 / 65536 }),

        .init(pid: 0x10, name: "Масова витрата повітря (ДМРВ)", shortName: "Витрата повітря (ДМРВ)", unit: "г/с", scaleMin: 0, scaleMax: 200, decimals: 1, category: .air, bytes: 2, formula: { ab($0) / 100 }),
        .init(pid: 0x0B, name: "Абсолютний тиск у впускному колекторі (MAP)", shortName: "Тиск у колекторі (MAP)", unit: "кПа", scaleMin: 0, scaleMax: 255, decimals: 0, category: .air, bytes: 1, formula: { Double($0[0]) }),
        .init(pid: 0x33, name: "Атмосферний тиск", shortName: "Атм. тиск", unit: "кПа", scaleMin: 70, scaleMax: 110, decimals: 0, category: .air, bytes: 1, formula: { Double($0[0]) }),
        .init(pid: 0x0F, name: "Температура повітря на впуску", shortName: "Т° повітря на впуску", unit: "°C", scaleMin: -40, scaleMax: 100, decimals: 0, category: .air, bytes: 1, formula: temp),
        .init(pid: 0x46, name: "Температура повітря назовні", shortName: "Т° назовні", unit: "°C", scaleMin: -40, scaleMax: 60, decimals: 0, category: .air, bytes: 1, formula: temp),
        .init(pid: 0x11, name: "Положення дросельної заслінки", shortName: "Дросельна заслінка", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x45, name: "Відносне положення дроселя", shortName: "Дросель відн.", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x4C, name: "Задане положення дроселя", shortName: "Дросель заданий", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x49, name: "Положення педалі газу", shortName: "Педаль газу", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x2C, name: "Заданий ступінь відкриття EGR", shortName: "EGR задано", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x2D, name: "Похибка EGR", shortName: "EGR похибка", unit: "%", scaleMin: -100, scaleMax: 100, decimals: 0, category: .air, bytes: 1, formula: trim),

        .init(pid: 0x14, name: "Лямбда-зонд 1 (ряд 1, до каталізатора)", shortName: "Лямбда до каталізатора", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x15, name: "Лямбда-зонд 2 (ряд 1, після каталізатора)", shortName: "Лямбда після каталізатора", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x18, name: "Лямбда-зонд 1 (ряд 2, до каталізатора)", shortName: "Лямбда B2S1", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x19, name: "Лямбда-зонд 2 (ряд 2, після каталізатора)", shortName: "Лямбда B2S2", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x3C, name: "Температура каталізатора (ряд 1)", shortName: "Т° каталізатора", unit: "°C", scaleMin: 0, scaleMax: 1000, decimals: 0, category: .exhaust, bytes: 2, formula: { ab($0) / 10 - 40 }),

        .init(pid: 0x42, name: "Напруга бортової мережі (на блоці)", shortName: "Напруга мережі", unit: "В", scaleMin: 10, scaleMax: 16, decimals: 2, category: .electric, bytes: 2, formula: { ab($0) / 1000 }),

        .init(pid: 0x21, name: "Пробіг з горящою лампою Check Engine", shortName: "Пробіг з помилкою", unit: "км", scaleMin: 0, scaleMax: 10000, decimals: 0, category: .other, bytes: 2, formula: ab),
        .init(pid: 0x31, name: "Пробіг після стирання помилок", shortName: "Пробіг після стирання", unit: "км", scaleMin: 0, scaleMax: 10000, decimals: 0, category: .other, bytes: 2, formula: ab),
        // — Додаткові параметри —
        .init(pid: 0x16, name: "Лямбда-зонд 3 (ряд 1)", shortName: "Лямбда B1S3", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x17, name: "Лямбда-зонд 4 (ряд 1)", shortName: "Лямбда B1S4", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x1A, name: "Лямбда-зонд 3 (ряд 2)", shortName: "Лямбда B2S3", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x1B, name: "Лямбда-зонд 4 (ряд 2)", shortName: "Лямбда B2S4", unit: "В", scaleMin: 0, scaleMax: 1.1, decimals: 2, category: .exhaust, bytes: 2, formula: { Double($0[0]) / 200 }),
        .init(pid: 0x24, name: "Широкосмуговий зонд B1S1: склад суміші", shortName: "λ B1S1", unit: "λ", scaleMin: 0.6, scaleMax: 1.4, decimals: 3, category: .exhaust, bytes: 4, formula: { ab($0) * 2 / 65536 }),
        .init(pid: 0x25, name: "Широкосмуговий зонд B1S2: склад суміші", shortName: "λ B1S2", unit: "λ", scaleMin: 0.6, scaleMax: 1.4, decimals: 3, category: .exhaust, bytes: 4, formula: { ab($0) * 2 / 65536 }),
        .init(pid: 0x28, name: "Широкосмуговий зонд B2S1: склад суміші", shortName: "λ B2S1", unit: "λ", scaleMin: 0.6, scaleMax: 1.4, decimals: 3, category: .exhaust, bytes: 4, formula: { ab($0) * 2 / 65536 }),
        .init(pid: 0x34, name: "Широкосмуговий зонд B1S1: струм", shortName: "Струм λ B1S1", unit: "мА", scaleMin: -5, scaleMax: 5, decimals: 2, category: .exhaust, bytes: 4, formula: { (Double(Int($0[2]) * 256 + Int($0[3])) / 256) - 128 }),
        .init(pid: 0x3D, name: "Температура каталізатора (ряд 2)", shortName: "Т° кат. ряд 2", unit: "°C", scaleMin: 0, scaleMax: 1000, decimals: 0, category: .exhaust, bytes: 2, formula: { ab($0) / 10 - 40 }),
        .init(pid: 0x3E, name: "Температура каталізатора (ряд 1, датчик 2)", shortName: "Т° кат. B1S2", unit: "°C", scaleMin: 0, scaleMax: 1000, decimals: 0, category: .exhaust, bytes: 2, formula: { ab($0) / 10 - 40 }),
        .init(pid: 0x2E, name: "Задана продувка адсорбера (EVAP)", shortName: "Продувка EVAP", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .fuel, bytes: 1, formula: pct),
        .init(pid: 0x32, name: "Тиск парів палива в системі EVAP", shortName: "Тиск EVAP", unit: "Па", scaleMin: -2000, scaleMax: 2000, decimals: 0, category: .fuel, bytes: 2, formula: { Double(Int16(bitPattern: UInt16($0[0]) << 8 | UInt16($0[1]))) / 4 }),
        .init(pid: 0x52, name: "Вміст етанолу в паливі", shortName: "Етанол", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .fuel, bytes: 1, formula: pct),
        .init(pid: 0x59, name: "Абсолютний тиск у паливній рампі", shortName: "Тиск рампи (абс.)", unit: "бар", scaleMin: 0, scaleMax: 2500, decimals: 0, category: .fuel, bytes: 2, formula: { ab($0) * 0.1 }),
        .init(pid: 0x5D, name: "Момент упорскування палива", shortName: "Момент упорскування", unit: "°", scaleMin: -30, scaleMax: 30, decimals: 1, category: .fuel, bytes: 2, formula: { ab($0) / 128 - 210 }),
        .init(pid: 0x47, name: "Положення дроселя B", shortName: "Дросель B", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x48, name: "Положення дроселя C", shortName: "Дросель C", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x4A, name: "Положення педалі газу E", shortName: "Педаль E", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x4B, name: "Положення педалі газу F", shortName: "Педаль F", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x5A, name: "Відносне положення педалі газу", shortName: "Педаль відн.", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 1, category: .air, bytes: 1, formula: pct),
        .init(pid: 0x61, name: "Крутний момент, який просить водій", shortName: "Момент (запит)", unit: "%", scaleMin: -25, scaleMax: 100, decimals: 0, category: .engine, bytes: 1, formula: { Double($0[0]) - 125 }),
        .init(pid: 0x62, name: "Фактичний крутний момент двигуна", shortName: "Момент (факт)", unit: "%", scaleMin: -25, scaleMax: 100, decimals: 0, category: .engine, bytes: 1, formula: { Double($0[0]) - 125 }),
        .init(pid: 0x63, name: "Номінальний крутний момент двигуна", shortName: "Момент номін.", unit: "Н·м", scaleMin: 0, scaleMax: 800, decimals: 0, category: .engine, bytes: 2, formula: ab),
        .init(pid: 0x5B, name: "Заряд гібридної батареї", shortName: "Гібрид. батарея", unit: "%", scaleMin: 0, scaleMax: 100, decimals: 0, category: .electric, bytes: 1, formula: pct),
        .init(pid: 0x30, name: "Кількість прогрівів після стирання помилок", shortName: "Прогрівів після стирання", unit: "", scaleMin: 0, scaleMax: 255, decimals: 0, category: .other, bytes: 1, formula: { Double($0[0]) }),
        .init(pid: 0x4D, name: "Час роботи з горящим Check Engine", shortName: "Час з помилкою", unit: "хв", scaleMin: 0, scaleMax: 10000, decimals: 0, category: .other, bytes: 2, formula: ab),
        .init(pid: 0x4E, name: "Час після стирання помилок", shortName: "Час після стирання", unit: "хв", scaleMin: 0, scaleMax: 10000, decimals: 0, category: .other, bytes: 2, formula: ab),


        // — Розширені параметри (новіші авто, дизелі, турбо) —
        .init(pid: 0x26, name: "Широкосмуговий зонд B1S3: склад суміші", shortName: "λ B1S3", unit: "λ", scaleMin: 0.6, scaleMax: 1.4, decimals: 3, category: .exhaust, bytes: 4, formula: { ab($0) * 2 / 65536 }),
        .init(pid: 0x29, name: "Широкосмуговий зонд B2S2: склад суміші", shortName: "λ B2S2", unit: "λ", scaleMin: 0.6, scaleMax: 1.4, decimals: 3, category: .exhaust, bytes: 4, formula: { ab($0) * 2 / 65536 }),
        .init(pid: 0x35, name: "Широкосмуговий зонд B1S2: струм", shortName: "Струм λ B1S2", unit: "мА", scaleMin: -5, scaleMax: 5, decimals: 2, category: .exhaust, bytes: 4, formula: { (Double(Int($0[2]) * 256 + Int($0[3])) / 256) - 128 }),
        .init(pid: 0x3F, name: "Температура каталізатора (ряд 2, датчик 2)", shortName: "Т° кат. B2S2", unit: "°C", scaleMin: 0, scaleMax: 1000, decimals: 0, category: .exhaust, bytes: 2, formula: { ab($0) / 10 - 40 }),
        .init(pid: 0x55, name: "Коротка корекція за другим зондом, ряд 1", shortName: "Корекція 2-го зонда кор. 1", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 2, formula: trim),
        .init(pid: 0x56, name: "Довга корекція за другим зондом, ряд 1", shortName: "Корекція 2-го зонда довга 1", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 2, formula: trim),
        .init(pid: 0x57, name: "Коротка корекція за другим зондом, ряд 2", shortName: "Корекція 2-го зонда кор. 2", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 2, formula: trim),
        .init(pid: 0x58, name: "Довга корекція за другим зондом, ряд 2", shortName: "Корекція 2-го зонда довга 2", unit: "%", scaleMin: -25, scaleMax: 25, decimals: 1, category: .fuel, bytes: 2, formula: trim),
        .init(pid: 0x67, name: "Температура рідини, датчик 1 (розширений)", shortName: "Т° ОР датчик 1", unit: "°C", scaleMin: -40, scaleMax: 130, decimals: 0, category: .engine, bytes: 3, formula: { Double($0[1]) - 40 }),
        .init(pid: 0x6F, name: "Тиск на вході компресора турбіни", shortName: "Тиск до турбіни", unit: "кПа", scaleMin: 50, scaleMax: 120, decimals: 0, category: .air, bytes: 3, formula: { Double($0[1]) }),
        .init(pid: 0x73, name: "Тиск вихлопних газів (ряд 1)", shortName: "Тиск вихлопу", unit: "кПа", scaleMin: 90, scaleMax: 300, decimals: 1, category: .exhaust, bytes: 5, formula: { Double(Int($0[1]) * 256 + Int($0[2])) * 0.01 }),
        .init(pid: 0x74, name: "Оберти турбіни", shortName: "Оберти турбіни", unit: "об/хв", scaleMin: 0, scaleMax: 250000, decimals: 0, category: .air, bytes: 5, formula: { Double(Int($0[1]) * 256 + Int($0[2])) * 10 }),
        .init(pid: 0x77, name: "Температура повітря після інтеркулера", shortName: "Т° після інтеркулера", unit: "°C", scaleMin: -40, scaleMax: 120, decimals: 0, category: .air, bytes: 5, formula: { Double($0[1]) - 40 }),
        .init(pid: 0x78, name: "Температура вихлопних газів (ряд 1, датчик 1)", shortName: "Т° вихлопу", unit: "°C", scaleMin: 0, scaleMax: 900, decimals: 0, category: .exhaust, bytes: 9, formula: { Double(Int($0[1]) * 256 + Int($0[2])) * 0.1 - 40 }),
        .init(pid: 0x7A, name: "Перепад тиску на сажовому фільтрі (DPF)", shortName: "Перепад DPF", unit: "кПа", scaleMin: 0, scaleMax: 40, decimals: 2, category: .exhaust, bytes: 7, formula: { Double(Int($0[1]) * 256 + Int($0[2])) * 0.01 }),
        .init(pid: 0x7C, name: "Температура на вході сажового фільтра (DPF)", shortName: "Т° DPF", unit: "°C", scaleMin: 0, scaleMax: 800, decimals: 0, category: .exhaust, bytes: 9, formula: { Double(Int($0[1]) * 256 + Int($0[2])) * 0.1 - 40 }),
        .init(pid: 0x7F, name: "Загальний час роботи двигуна", shortName: "Мотогодини", unit: "год", scaleMin: 0, scaleMax: 20000, decimals: 0, category: .other, bytes: 13, formula: { Double((Int($0[1]) << 24) | (Int($0[2]) << 16) | (Int($0[3]) << 8) | Int($0[4])) / 3600 }),
        .init(pid: 0x8E, name: "Момент тертя двигуна", shortName: "Момент тертя", unit: "%", scaleMin: -25, scaleMax: 50, decimals: 0, category: .engine, bytes: 1, formula: { Double($0[0]) - 125 }),
        .init(pid: 0xA4, name: "Поточна передача коробки", shortName: "Передача", unit: "", scaleMin: 0, scaleMax: 8, decimals: 0, category: .engine, bytes: 4, formula: { Double($0[1] >> 4) }),
        .init(pid: 0xA6, name: "Пробіг за одометром (авто з 2019 р.)", shortName: "Одометр", unit: "км", scaleMin: 0, scaleMax: 500000, decimals: 0, category: .other, bytes: 4, formula: { Double((Int($0[0]) << 24) | (Int($0[1]) << 16) | (Int($0[2]) << 8) | Int($0[3])) / 10 }),

        // — Віртуальні параметри (рахує програма або адаптер) —
        .init(pid: 0xF0, name: "Напруга акумулятора (вимірює адаптер)", shortName: "АКБ (адаптер)", unit: "В", scaleMin: 10, scaleMax: 16, decimals: 2, category: .electric, bytes: 0, formula: { _ in 0 }),
        .init(pid: 0xF1, name: "Загальна корекція палива, ряд 1 (коротка + довга)", shortName: "Корекція палива сумарна", unit: "%", scaleMin: -30, scaleMax: 30, decimals: 1, category: .fuel, bytes: 0, formula: { _ in 0 }),
    ]

    public static let byPID: [UInt8: PIDDefinition] = {
        var d: [UInt8: PIDDefinition] = [:]
        for p in all { d[p.pid] = p }
        return d
    }()

    public static func definition(_ pid: UInt8) -> PIDDefinition? { byPID[pid] }

    /// Набір за замовчуванням для екрана «Живі дані».
    public static let defaultSelection: [UInt8] = [0x0C, 0x05, 0x04, 0x10, 0x0B, 0x06, 0x07, 0xF1, 0x14, 0x15, 0x11, 0x0F, 0x0E, 0x42, 0xF0]
}
