#if os(macOS)
import Foundation
import AutoScanCore

/// Знімок стану авто в певний момент (до або після ремонту).
struct DiagnosticSnapshot: Codable, Equatable {
    struct Code: Codable, Equatable, Hashable {
        var code: String
        var title: String
        var kind: String
        var severity: Int
    }
    struct Reading: Codable, Equatable {
        var label: String
        var value: String
    }
    struct Check: Codable, Equatable {
        var code: String
        var title: String
        var actual: String
        var verdict: String
        var problem: Bool
    }

    var date: Date
    var milOn: Bool?
    var codes: [Code]
    var readings: [Reading]
    var checks: [Check]

    var codeSet: Set<String> { Set(codes.map(\.code)) }
}

/// Дані одного клієнта / замовлення для акту.
struct ServiceJob: Codable, Equatable {
    var clientName = ""
    var clientPhone = ""
    var carTitle = ""
    var plate = ""
    var vin = ""
    var mileage = ""
    var complaint = ""
    var works = ""
    var parts = ""
    var recommendations = ""
    var before: DiagnosticSnapshot?
    var after: DiagnosticSnapshot?
    var created = Date()

    static let storageKey = "currentServiceJob"

    static func load() -> ServiceJob {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let job = try? JSONDecoder().decode(ServiceJob.self, from: data) else { return ServiceJob() }
        return job
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Рядки списку (кожен рядок тексту — окремий пункт).
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("-") || $0.hasPrefix("•") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 }
            .filter { !$0.isEmpty }
    }
}

/// Дані сервісу (шапка акту) — зберігаються між клієнтами.
struct ServiceProfile: Codable, Equatable {
    var name = ""
    var phone = ""
    var address = ""
    var master = ""

    static let storageKey = "serviceProfile"

    static func load() -> ServiceProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let p = try? JSONDecoder().decode(ServiceProfile.self, from: data) else { return ServiceProfile() }
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

extension ServiceJob {
    /// Зразок для перевірки вигляду PDF.
    static var sample: ServiceJob {
        var j = ServiceJob()
        j.clientName = "Іван Петренко"; j.clientPhone = "+380 67 123 45 67"
        j.carTitle = "Volkswagen Passat B7, 1.8 TSI, 2014"; j.plate = "AT 1234 BC"
        j.vin = "WVWZZZ3CZEE123456"; j.mileage = "184 500"
        j.complaint = "Горить Check Engine, машина смикається на холостих і погано тягне при розгоні."
        j.works = "Комп'ютерна діагностика\nЗаміна свічок запалювання\nЗаміна котушки 1-го циліндра\nУсунення підсмоктування повітря (патрубок вентиляції картера)\nСтирання помилок, перевірка на ходу"
        j.parts = "Свічки запалювання NGK — 4 шт.\nКотушка запалювання — 1 шт.\nПатрубок вентиляції картера — 1 шт."
        j.recommendations = "Перевірити інтеркулер і патрубки наддуву при наступному ТО\nЗамінити повітряний фільтр через 5 000 км"
        let d1 = Date().addingTimeInterval(-3 * 3600)
        j.before = DiagnosticSnapshot(date: d1, milOn: true, codes: [
            .init(code: "P0171", title: "Занадто бідна суміш, ряд 1 (сторона 1-го циліндра)", kind: "Активна", severity: 2),
            .init(code: "P0299", title: "Недостатній тиск наддуву", kind: "Активна", severity: 2),
            .init(code: "P0301", title: "Пропуски запалювання в 1-му циліндрі", kind: "Очікувана", severity: 3)],
            readings: [.init(label: "Оберти двигуна", value: "790 об/хв"), .init(label: "Температура охолоджувальної рідини", value: "91 °C"),
                       .init(label: "Напруга бортової мережі", value: "14.10 В"), .init(label: "Довга корекція палива, ряд 1", value: "17.9 %"),
                       .init(label: "Масова витрата повітря (ДМРВ)", value: "3.1 г/с")],
            checks: [.init(code: "P0171", title: "Довга корекція палива, ряд 1", actual: "17.9 %", verdict: "Вище норми", problem: true),
                     .init(code: "P0301", title: "Рівність обертів холостого ходу", actual: "790 об/хв, ±48", verdict: "Сигнал нестабільний", problem: true)])
        j.after = DiagnosticSnapshot(date: Date(), milOn: false, codes: [
            .init(code: "P0299", title: "Недостатній тиск наддуву", kind: "Очікувана", severity: 2)],
            readings: [.init(label: "Оберти двигуна", value: "760 об/хв"), .init(label: "Довга корекція палива, ряд 1", value: "2.3 %")],
            checks: [])
        return j
    }
}

extension ServiceProfile {
    static var sample: ServiceProfile {
        ServiceProfile(name: "Автосервіс «Приклад»", phone: "+380 50 000 00 00", address: "м. Коломия, вул. Прикладна, 1", master: "Роман")
    }
}

extension AppModel {
    /// Зафіксувати поточний стан авто: помилки, основні показники, «норма vs зараз».
    func makeSnapshot() -> DiagnosticSnapshot {
        let codes = dtcs.map { d -> DiagnosticSnapshot.Code in
            let e = entry(for: d).entry
            return .init(code: d.code, title: e.title, kind: d.kind.title, severity: e.severity)
        }
        let keyPIDs: [UInt8] = [0x0C, 0x05, 0x42, 0x07, 0x06, 0x10, 0x0B, 0x0F, 0x23]
        let readings = keyPIDs.compactMap { pid -> DiagnosticSnapshot.Reading? in
            guard let def = PIDTable.definition(pid), let v = live.values[pid] else { return nil }
            return .init(label: def.name, value: def.format(v) + " " + def.unit)
        }
        let ctx = normContext(live)
        var checks: [DiagnosticSnapshot.Check] = []
        for code in uniqueCodes {
            for ch in self.checks(for: code) {
                let r = ch.evaluate(ctx)
                guard r.verdict != .waiting else { continue }
                checks.append(.init(code: code, title: ch.title, actual: r.actualText,
                                    verdict: r.verdict.title, problem: r.verdict.isProblem))
            }
        }
        return DiagnosticSnapshot(date: Date(), milOn: monitor?.milOn, codes: codes, readings: readings, checks: checks)
    }

    /// Назва авто для акту: з демо, VIN або вказана вручну марка.
    var carTitleGuess: String {
        if let d = demoScenario { return "\(d.car), \(d.engine), \(d.year)" }
        if let v = vin, let m = v.manufacturer {
            return [m, v.modelYear.map { "\($0) р." }].compactMap { $0 }.joined(separator: ", ")
        }
        return manualBrand
    }
}
#endif
