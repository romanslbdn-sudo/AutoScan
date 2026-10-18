import Foundation

/// Розшифровка VIN-коду (виробник, країна, модельний рік).
public struct VINInfo: Hashable, Sendable {
    public let vin: String
    public let manufacturer: String?
    public let country: String?
    public let modelYear: Int?

    public init(vin raw: String, currentYear: Int = Calendar.current.component(.year, from: Date())) {
        let vin = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        self.vin = vin
        let chars = Array(vin)
        guard chars.count == 17 else {
            manufacturer = nil; country = nil; modelYear = nil
            return
        }
        let wmi = String(chars[0..<3])
        manufacturer = VINInfo.manufacturer(for: wmi)
        country = VINInfo.country(for: String(chars[0..<2]))
        modelYear = VINInfo.year(for: chars[9], currentYear: currentYear)
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

    static func year(for c: Character, currentYear: Int) -> Int? {
        let letters = Array("ABCDEFGHJKLMNPRSTVWXY")
        if let idx = letters.firstIndex(of: c) {
            let modern = 2010 + idx
            return modern <= currentYear + 1 ? modern : 1980 + idx
        }
        if let d = c.wholeNumberValue, d >= 1 { return 2000 + d }
        return nil
    }
}
