import Foundation

/// Опис коду несправності.
public struct DTCEntry: Codable, Hashable, Sendable {
    public let code: String
    public let title: String
    public let details: String
    public let causes: [String]
    public let severity: Int

    enum CodingKeys: String, CodingKey {
        case code = "c", title = "t", details = "d", causes = "r", severity = "s"
    }

    public init(code: String, title: String, details: String, causes: [String], severity: Int) {
        self.code = code; self.title = title; self.details = details; self.causes = causes; self.severity = severity
    }

    public var severityTitle: String {
        switch severity {
        case 3: return "Серйозно — краще не їздити до ремонту"
        case 2: return "Перевірити найближчим часом"
        default: return "Можна їздити, виправити при нагоді"
        }
    }
}

/// Пакет даних під конкретну марку: заводські коди та примітки.
public struct BrandPack: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var brand: String
    public var title: String
    public var version: String
    /// Назви марки, як їх повертає розшифровка VIN (напр. ["Volkswagen", "Audi", "Skoda", "Seat"]).
    public var matches: [String]
    public var notes: String?
    public var codes: [DTCEntry]

    public init(id: String, brand: String, title: String, version: String, matches: [String], notes: String?, codes: [DTCEntry]) {
        self.id = id; self.brand = brand; self.title = title; self.version = version
        self.matches = matches; self.notes = notes; self.codes = codes
    }

    public func applies(toBrand brand: String?) -> Bool {
        guard let brand = brand?.lowercased() else { return false }
        return matches.contains { brand.hasPrefix($0.lowercased()) }
    }

    /// Шаблон для створення власного пакета.
    public static let template = BrandPack(
        id: "my-brand",
        brand: "Назва марки",
        title: "Мій пакет для марки",
        version: "1.0",
        matches: ["Назва марки, як у VIN (напр. Volkswagen)"],
        notes: "Примітки про особливості діагностики цієї марки.",
        codes: [DTCEntry(code: "P1234", title: "Коротка назва", details: "Пояснення простими словами.",
                         causes: ["Найімовірніша причина", "Друга причина"], severity: 2)]
    )
}

private struct GenericFile: Codable {
    let version: Int
    let codes: [DTCEntry]
}

/// База описів кодів: загальна (SAE) + завантажені пакети марок.
public final class DTCDatabase: @unchecked Sendable {
    public private(set) var generic: [String: DTCEntry] = [:]
    public private(set) var packs: [BrandPack] = []
    public let packsDirectory: URL

    public init(packsDirectory: URL? = nil) {
        let dir = packsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoScan/Packs", isDirectory: true)
        self.packsDirectory = dir
        loadGeneric()
        reloadPacks()
    }

    public var genericCount: Int { generic.count }

    private func loadGeneric() {
        guard let file = try? JSONDecoder().decode(GenericFile.self, from: Data(GenericDTCData.json.utf8)) else { return }
        for e in file.codes { generic[e.code] = e }
    }

    public func reloadPacks() {
        try? FileManager.default.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: packsDirectory, includingPropertiesForKeys: nil)) ?? []
        packs = files.filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { try? JSONDecoder().decode(BrandPack.self, from: Data(contentsOf: $0)) }
            .sorted { $0.brand < $1.brand }
    }

    /// Перевіряє файл і копіює його в папку пакетів.
    @discardableResult
    public func importPack(from url: URL) throws -> BrandPack {
        try importPack(data: Data(contentsOf: url))
    }

    /// Встановлює пакет з даних (напр. завантажених з інтернету).
    @discardableResult
    public func importPack(data: Data) throws -> BrandPack {
        let pack: BrandPack
        do {
            pack = try JSONDecoder().decode(BrandPack.self, from: data)
        } catch {
            throw AdapterError.transport("Файл не схожий на пакет AutoScan: \(error.localizedDescription)")
        }
        try FileManager.default.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        let dest = packsDirectory.appendingPathComponent(Self.safeFileName(pack.id) + ".json")
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        reloadPacks()
        return pack
    }

    public func removePack(_ pack: BrandPack) {
        let dest = packsDirectory.appendingPathComponent(Self.safeFileName(pack.id) + ".json")
        try? FileManager.default.removeItem(at: dest)
        reloadPacks()
    }

    static func safeFileName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "pack" : cleaned
    }

    public func packs(forBrand brand: String?) -> [BrandPack] {
        packs.filter { $0.applies(toBrand: brand) }
    }

    /// Опис коду: спершу пакет марки, далі загальна база, далі опис за структурою коду.
    public func lookup(_ code: String, brand: String?) -> (entry: DTCEntry, source: String) {
        let code = code.uppercased()
        for pack in packs(forBrand: brand) {
            if let e = pack.codes.first(where: { $0.code.uppercased() == code }) {
                return (e, pack.title)
            }
        }
        if let e = generic[code] { return (e, "Загальна база OBD2") }
        // Код з пакета будь-якої марки — краще, ніж нічого, але з приміткою.
        for pack in packs {
            if let e = pack.codes.first(where: { $0.code.uppercased() == code }) {
                return (e, "\(pack.title) (марка авто не визначена — перевірте відповідність)")
            }
        }
        return (Self.structuralDescription(code), "Розшифровка за структурою коду")
    }

    public func installedPack(id: String) -> BrandPack? { packs.first { $0.id == id } }

    /// Загальний опис, коли коду немає в базах.
    public static func structuralDescription(_ code: String) -> DTCEntry {
        let dtc = DTC(code: code, kind: .stored)
        let chars = Array(code)
        var area = dtc.systemTitle
        if chars.count == 5, chars[0] == "P" {
            switch chars[2] {
            case "0", "1", "2": area = "Подача палива і повітря"
            case "3": area = "Система запалювання або пропуски запалювання"
            case "4": area = "Допоміжні екологічні системи (EGR, EVAP, каталізатор)"
            case "5": area = "Швидкість авто, холостий хід, допоміжні входи"
            case "6": area = "Блок керування та його вихідні кола"
            case "7", "8", "9": area = "Коробка передач"
            case "A", "B", "C": area = "Гібридна / електрична силова установка"
            default: break
            }
        }
        let specific = dtc.isManufacturerSpecific
        let details = specific
            ? "Це заводський код марки — його значення залежить від виробника. Завантажте пакет для своєї марки в розділі «Бази авто», щоб отримати точний опис. Область: \(area.lowercased())."
            : "Цього коду поки немає в базі програми. Область несправності: \(area.lowercased())."
        return DTCEntry(code: code, title: area, details: details,
                        causes: ["Потрібна додаткова перевірка за документацією виробника"], severity: 2)
    }
}
