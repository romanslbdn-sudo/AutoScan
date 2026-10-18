import Foundation

/// Розшифровка VIN-коду (виробник, країна, модельний рік).
public struct VINInfo: Hashable, Sendable {
    public let vin: String
    public let manufacturer: String?
    public let country: String?
    /// Рік, якщо його можна визначити однозначно.
    public let modelYear: Int?
    /// Усі можливі роки за 10-м символом (одна літера повторюється кожні 30 років: G = 1986 або 2016).
    public let yearCandidates: [Int]
    /// Пояснення, чому рік неоднозначний або не визначається.
    public let yearNote: String?
    /// Стандарт, за яким складено номер (визначається автоматично).
    public let region: VINRegion
    /// Модель і роки випуску — для марок з відомим форматом VIN.
    public let brandInfo: BrandVINInfo?

    /// - Parameter minYear: нижня межа року, якщо вона відома (напр. 1996 для авто, що відповіли через OBD2).
    public init(vin raw: String, currentYear: Int = Calendar.current.component(.year, from: Date()), minYear: Int? = nil) {
        let vin = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        self.vin = vin
        let chars = Array(vin)
        region = chars.first.map(VINRegion.of) ?? .other
        guard chars.count == 17 else {
            manufacturer = nil; country = nil; modelYear = nil; yearCandidates = []; yearNote = nil; brandInfo = nil
            return
        }
        brandInfo = BrandVIN.decode(vin)
        let wmi = String(chars[0..<3])
        manufacturer = VINInfo.manufacturer(for: wmi)
        country = VINInfo.country(for: String(chars[0..<2]))

        var candidates = VINInfo.years(for: chars[9]).filter { $0 <= currentYear + 1 }
        if let min = minYear { candidates = candidates.filter { $0 >= min } }
        let northAmerica = ["1", "2", "3", "4", "5"].contains(String(chars[0]))
        if northAmerica && candidates.count > 1 {
            // Правило для авто США/Канади: 7-й символ — цифра для 1980–2009, літера для 2010–2039
            let modern = !(chars[6].isNumber)
            candidates = candidates.filter { modern ? $0 >= 2010 : $0 < 2010 }
        }
        // Mercedes не кодує рік у 10-му символі — покладаємося на роки випуску шасі
        if BrandVIN.mercedesWMI.contains(wmi) { candidates = [] }
        // Роки випуску моделі допомагають вибрати правильний варіант (напр. «E» у Passat B7 — 2014, а не 1984)
        if candidates.count > 1, let range = brandInfo?.years {
            let inRange = candidates.filter { range.contains($0) }
            if !inRange.isEmpty { candidates = inRange }
        }
        yearCandidates = candidates
        if candidates.count == 1 {
            modelYear = candidates[0]
            yearNote = northAmerica || brandInfo != nil ? nil : "Європейські виробники не завжди кодують рік у 10-му символі — звірте з техпаспортом."
        } else {
            modelYear = nil
            if let r = brandInfo?.years {
                yearNote = "Рік у цьому VIN не закодовано, але модель випускалась у \(r.lowerBound)–\(r.upperBound) роках."
            } else if candidates.isEmpty {
                yearNote = "Рік у цьому VIN не закодовано (так буває в багатьох європейських авто, особливо старших)."
            } else {
                yearNote = "За VIN рік однозначно не визначити: та сама позначка означає \(candidates.map(String.init).joined(separator: " або ")). Для старих європейських авто рік часто взагалі не закодовано в цьому символі — дивіться техпаспорт."
            }
        }
    }

    /// Рік текстом: «2014», «1986 або 2016» чи «не визначено».
    public var yearText: String {
        if let y = modelYear { return "\(y)" }
        if let r = brandInfo?.years, yearCandidates.isEmpty || yearCandidates.allSatisfy({ !r.contains($0) }) {
            return "\(r.lowerBound)–\(r.upperBound) (роки випуску моделі)"
        }
        if !yearCandidates.isEmpty { return yearCandidates.map(String.init).joined(separator: " або ") }
        return "не визначено"
    }

    /// 17 символів, лише латинські літери й цифри, без I, O, Q.
    public var isValidFormat: Bool {
        vin.count == 17 && !vin.contains { "IOQ".contains($0) }
    }

    /// Перевірка контрольної цифри (9-й символ). Обов'язкова для авто ринку США/Канади;
    /// європейські виробники часто її не використовують — тоді nil.
    public var checkDigitValid: Bool? {
        guard isValidFormat else { return nil }
        let chars = Array(vin)
        let map: [Character: Int] = ["A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8,
                                     "J": 1, "K": 2, "L": 3, "M": 4, "N": 5, "P": 7, "R": 9,
                                     "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9]
        let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
        var sum = 0
        for (i, c) in chars.enumerated() {
            guard let v = c.wholeNumberValue ?? map[c] else { return nil }
            sum += v * weights[i]
        }
        let r = sum % 11
        let expected: Character = r == 10 ? "X" : Character(String(r))
        if chars[8] == expected { return true }
        // Для європейських авто 9-й символ часто довільний — не вважаємо це помилкою
        let northAmerica = ["1", "2", "3", "4", "5"].contains(String(chars[0]))
        return northAmerica ? false : nil
    }

    /// Частини VIN: виробник (1–3), опис авто (4–9), рік (10), завод (11), серійний номер (12–17).
    public var parts: [(String, String)] {
        guard vin.count == 17 else { return [] }
        let c = Array(vin)
        return [(String(c[0..<3]), "Виробник (WMI)"), (String(c[3..<9]), "Модель, кузов, двигун (VDS)"),
                (String(c[9]), "Модельний рік"), (String(c[10]), "Завод"), (String(c[11..<17]), "Серійний номер")]
    }

    /// Назва марки для пошуку пакета даних (напр. "BMW").
    public var brandKey: String? {
        manufacturer.map { $0.components(separatedBy: " (").first ?? $0 }
    }

    static let wmiTable: [String: String] = [
        "WBA": "BMW", "WBS": "BMW (M)", "WBX": "BMW", "WBY": "BMW (i)", "WMW": "MINI",
        "WVW": "Volkswagen", "WV1": "Volkswagen (комерційні)", "WV2": "Volkswagen (комерційні)", "WVG": "Volkswagen (SUV)",
        "WAU": "Audi", "WUA": "Audi (quattro GmbH)", "TRU": "Audi (Угорщина)",
        "TMB": "Skoda", "VSS": "Seat", "VWV": "Volkswagen (Іспанія)",
        "WDB": "Mercedes-Benz", "WDD": "Mercedes-Benz", "WDC": "Mercedes-Benz (SUV)", "WDF": "Mercedes-Benz (комерційні)", "W1K": "Mercedes-Benz", "W1N": "Mercedes-Benz (SUV)", "W1V": "Mercedes-Benz (комерційні)",
        "WP0": "Porsche", "WP1": "Porsche (SUV)",
        "W0L": "Opel", "W0V": "Opel", "VXK": "Opel",
        "WF0": "Ford (Німеччина)", "1FA": "Ford (США)", "1FT": "Ford (США, вантажні)", "1FM": "Ford (США, SUV)", "SFA": "Ford (Велика Британія)", "NM0": "Ford (Туреччина)",
        "VF1": "Renault", "VF3": "Peugeot", "VF7": "Citroën", "VR3": "Peugeot", "VR7": "Citroën", "VR1": "DS",
        "UU1": "Dacia", "VF6": "Renault (вантажні)",
        "ZFA": "Fiat", "ZFF": "Ferrari", "ZAR": "Alfa Romeo", "ZLA": "Lancia", "ZCF": "Iveco",
        "SAL": "Land Rover", "SAJ": "Jaguar", "SCC": "Lotus", "SCF": "Aston Martin",
        "YV1": "Volvo", "YV4": "Volvo (SUV)", "YS3": "Saab",
        "JT": "Toyota", "JTD": "Toyota", "JTE": "Toyota", "JTM": "Toyota", "JTN": "Toyota", "SB1": "Toyota (Велика Британія)", "VNK": "Toyota (Франція)", "NMT": "Toyota (Туреччина)", "JTH": "Lexus",
        "JHM": "Honda", "JHL": "Honda", "SHH": "Honda (Велика Британія)", "SHS": "Honda (Велика Британія)",
        "JN1": "Nissan", "JN8": "Nissan (SUV)", "SJN": "Nissan (Велика Британія)", "VSK": "Nissan (Іспанія)",
        "JM1": "Mazda", "JMZ": "Mazda (Європа)", "JMB": "Mitsubishi", "JMY": "Mitsubishi", "JA3": "Mitsubishi", "JS1": "Suzuki (мото)", "JSA": "Suzuki", "TSM": "Suzuki (Угорщина)",
        "JF1": "Subaru", "JF2": "Subaru",
        "KMH": "Hyundai", "TMA": "Hyundai (Чехія)", "NLH": "Hyundai (Туреччина)", "KNA": "Kia", "KND": "Kia (SUV)", "U5Y": "Kia (Словаччина)", "KL1": "Chevrolet (Корея)", "KPT": "SsangYong",
        "XTA": "ВАЗ (Lada)", "Y6D": "ЗАЗ",
        "LSV": "Volkswagen (Китай)", "LFV": "FAW-Volkswagen", "LGX": "BYD", "LVS": "Ford (Китай)", "L6T": "Geely",
        "1G1": "Chevrolet (США)", "1GC": "Chevrolet (США, вантажні)", "1C4": "Chrysler / Jeep", "1J4": "Jeep", "1C6": "RAM", "2T1": "Toyota (Канада)", "5YJ": "Tesla", "7SA": "Tesla",
    ]

    static func manufacturer(for wmi: String) -> String? {
        if let m = wmiTable[wmi] { return m }
        if let m = wmiTable[String(wmi.prefix(2))] { return m }
        return nil
    }

    static func country(for prefix: String) -> String? {
        guard let first = prefix.first else { return nil }
        switch first {
        case "W": return "Німеччина"
        case "V":
            if let s = prefix.last, ("F"..."R").contains(s) { return "Франція" }
            if let s = prefix.last, ("S"..."W").contains(s) { return "Іспанія" }
            return "Європа"
        case "Z": return "Італія"
        case "S":
            if let s = prefix.last, ("A"..."M").contains(s) { return "Велика Британія" }
            return "Європа"
        case "Y":
            if let s = prefix.last, ("S"..."W").contains(s) { return "Швеція" }
            return "Європа"
        case "T":
            if let s = prefix.last, ("J"..."P").contains(s) { return "Чехія" }
            if let s = prefix.last, ("R"..."V").contains(s) { return "Угорщина" }
            return "Європа"
        case "U": return "Європа"
        case "X": return "Європа / СНД"
        case "J": return "Японія"
        case "K": return "Південна Корея"
        case "L": return "Китай"
        case "N": return "Туреччина"
        case "1", "4", "5": return "США"
        case "2": return "Канада"
        case "3": return "Мексика"
        case "6": return "Австралія"
        case "7": return "Нова Зеландія"
        case "8": return "Південна Америка"
        case "9": return "Бразилія"
        default: return nil
        }
    }

    static func years(for c: Character) -> [Int] {
        let letters = Array("ABCDEFGHJKLMNPRSTVWXY")
        if let idx = letters.firstIndex(of: c) { return [1980 + idx, 2010 + idx] }
        if let d = c.wholeNumberValue, d >= 1 { return [2000 + d, 2030 + d] }
        return []
    }
}
