import Foundation

/// Повні відомості про авто, зібрані з VIN, з самого авто і з датчиків.
public struct VehicleDetails: Sendable, Equatable {
    public var make: String?
    public var model: String?
    public var trim: String?
    public var year: Int?
    public var displacementL: Double?
    public var cylinders: Int?
    public var powerKW: Int?
    public var fuel: String?
    public var turbo: Bool?
    public var engineCode: String?
    public var body: String?
    public var drive: String?
    public var transmission: String?
    public var plant: String?
    /// Звідки дані (для підпису «джерело»).
    public var source: String

    public init(source: String) { self.source = source }

    /// «1.8 л · бензин · турбо» — коротко про двигун.
    public var engineSummary: String? {
        var parts: [String] = []
        if let d = displacementL { parts.append(String(format: "%.1f л", d).replacingOccurrences(of: ".", with: ",")) }
        if let f = fuel { parts.append(f) }
        if let t = turbo { parts.append(t ? "турбо" : "атмосферний") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var powerText: String? {
        guard let kw = powerKW, kw > 0 else { return nil }
        return "\(kw) кВт (\(Int((Double(kw) * 1.36).rounded())) к.с.)"
    }
}

/// Розбір відповіді безкоштовної бази VIN NHTSA (vpic.nhtsa.dot.gov).
/// Найповніші дані — для авто американського ринку; для європейських часто є марка, рік і частина даних про двигун.
public enum NHTSADecoder {
    public static func url(vin: String) -> URL? {
        URL(string: "https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/\(vin)?format=json")
    }

    public static func parse(_ data: Data) -> VehicleDetails? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["Results"] as? [[String: Any]], let r = results.first else { return nil }
        func s(_ k: String) -> String? {
            guard let v = r[k] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t == "Not Applicable" ? nil : t
        }
        var d = VehicleDetails(source: "онлайн-база VIN (NHTSA)")
        d.make = s("Make").map { $0.capitalized }
        d.model = s("Model")
        d.trim = [s("Series"), s("Trim")].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        d.year = s("ModelYear").flatMap { Int($0) }
        d.displacementL = s("DisplacementL").flatMap { Double($0) }.map { ($0 * 10).rounded() / 10 }
        d.cylinders = s("EngineCylinders").flatMap { Int($0) }
        if let kw = s("EngineKW").flatMap({ Double($0) }) { d.powerKW = Int(kw.rounded()) }
        else if let hp = s("EngineHP").flatMap({ Double($0) }) { d.powerKW = Int((hp * 0.7457).rounded()) }
        d.fuel = s("FuelTypePrimary").map(fuelUA)
        if let t = s("Turbo")?.lowercased() { d.turbo = t.hasPrefix("y") }
        d.engineCode = s("EngineModel")
        d.body = s("BodyClass").map(bodyUA)
        d.drive = s("DriveType").map(driveUA)
        d.transmission = s("TransmissionStyle").map(transUA)
        d.plant = [s("PlantCity").map { $0.capitalized }, s("PlantCountry").map { $0.capitalized }].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
        // Немає нічого корисного — вважаємо, що VIN не розпізнано
        if d.model == nil && d.displacementL == nil && d.fuel == nil && d.make == nil { return nil }
        return d
    }

    static func fuelUA(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("diesel") { return "дизель" }
        if l.contains("electric") && !l.contains("hybrid") { return "електро" }
        if l.contains("hybrid") { return "гібрид" }
        if l.contains("natural gas") { return "метан" }
        if l.contains("liquefied petroleum") || l.contains("lpg") || l.contains("propane") { return "газ (пропан)" }
        if l.contains("flexible") || l.contains("ethanol") { return "бензин / етанол" }
        if l.contains("gasoline") || l.contains("petrol") { return "бензин" }
        return s
    }

    static func bodyUA(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("sedan") || l.contains("saloon") { return "седан" }
        if l.contains("hatchback") || l.contains("liftback") { return "хетчбек" }
        if l.contains("wagon") { return "універсал" }
        if l.contains("sport utility") || l.contains("suv") || l.contains("crossover") { return "позашляховик / кросовер" }
        if l.contains("minivan") || l.contains("multi-purpose") { return "мінівен" }
        if l.contains("coupe") { return "купе" }
        if l.contains("convertible") || l.contains("cabriolet") { return "кабріолет" }
        if l.contains("pickup") { return "пікап" }
        if l.contains("van") { return "фургон" }
        return s
    }

    static func driveUA(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("4wd") || l.contains("4x4") || l.contains("4-wheel") { return "повний (4x4)" }
        if l.contains("awd") || l.contains("all-wheel") { return "повний" }
        if l.contains("fwd") || l.contains("front") { return "передній" }
        if l.contains("rwd") || l.contains("rear") { return "задній" }
        return s
    }

    static func transUA(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("cvt") || l.contains("continuously") { return "варіатор" }
        if l.contains("dual-clutch") || l.contains("dct") { return "робот (2 зчеплення)" }
        if l.contains("automated manual") { return "робот" }
        if l.contains("automatic") { return "автомат" }
        if l.contains("manual") || l.contains("standard") { return "механіка" }
        return s
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Відомості, які повідомляє саме авто (режим 01).
public enum VehicleInfoCodes {
    /// PID 01 51 — тип палива.
    public static func fuelType(_ code: UInt8) -> String? {
        switch code {
        case 1: return "бензин"
        case 2: return "метанол"
        case 3: return "етанол"
        case 4: return "дизель"
        case 5: return "газ (пропан)"
        case 6: return "метан"
        case 8: return "електро"
        case 9, 10: return "бензин / етанол"
        case 17, 18, 19, 20, 21, 22, 23: return "гібрид"
        default: return nil
        }
    }

    /// PID 01 1C — за яким стандартом сертифіковане авто.
    public static func obdStandard(_ code: UInt8) -> String? {
        switch code {
        case 1: return "OBD-II (США, CARB)"
        case 2: return "OBD (США, EPA)"
        case 3: return "OBD і OBD-II (США)"
        case 6: return "EOBD (Європа)"
        case 7: return "EOBD і OBD-II"
        case 9: return "EOBD, OBD і OBD-II"
        case 10: return "JOBD (Японія)"
        case 11: return "JOBD і OBD-II"
        case 12: return "JOBD і EOBD"
        case 13: return "JOBD, EOBD і OBD-II"
        case 17: return "EMD (дизелі США)"
        case 18, 19, 20, 21, 22: return "Euro / EOBD (вантажні)"
        case 23, 24, 25, 26: return "HD OBD"
        case 28: return "Бразилія (OBD-Br)"
        case 29: return "Корея (KOBD)"
        case 30: return "Індія (IOBD)"
        case 31: return "Китай (CN-OBD)"
        default: return nil
        }
    }
}

/// Оцінки за даними датчиків.
public enum EngineEstimator {
    /// Приблизний робочий об'єм двигуна (л) за витратою повітря на холостому ходу.
    /// Фізика: маса повітря = коефіцієнт наповнення × об'єм × оберти/2 × густина повітря в колекторі.
    /// Точність ±20 %, тому результат округлюється до поширених значень.
    public static func displacement(mafGs: Double, mapKPa: Double, rpm: Double, intakeC: Double, diesel: Bool) -> Double? {
        guard mafGs > 0.5, mapKPa > 15, rpm > 450, rpm < 1400 else { return nil }
        let ve = diesel ? 0.90 : 0.85
        let tK = intakeC + 273.15
        let litres = (mafGs / 1000) * 120 * 287.05 * tK / (ve * rpm * mapKPa * 1000) * 1000
        guard litres > 0.6, litres < 7.5 else { return nil }
        let common: [Double] = [0.8, 1.0, 1.2, 1.4, 1.5, 1.6, 1.8, 1.9, 2.0, 2.2, 2.4, 2.5, 2.7, 3.0, 3.5, 4.0, 4.4, 5.0, 6.0]
        return common.min { abs($0 - litres) < abs($1 - litres) }
    }

    /// Чи є турбіна: тиск у колекторі під навантаженням помітно вищий за атмосферний.
    public static func turbo(mapHistory: [Double], baro: Double?, diesel: Bool) -> Bool? {
        let b = baro ?? 100
        if let peak = mapHistory.max(), peak > b + 15 { return true }
        return nil
    }
}
