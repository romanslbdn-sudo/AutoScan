import Foundation

/// Розшифровка частин VIN, специфічних для марки (там, де формат добре відомий).
public struct BrandVINInfo: Sendable, Hashable {
    public let model: String
    public let years: ClosedRange<Int>?
    public let detail: String
}

public enum BrandVIN {

    /// VW / Audi / Škoda / Seat: 7–8 символи — код моделі (платформи).
    static let vag: [String: (String, Int, Int)] = [
        "1J": ("VW Golf IV / Bora", 1997, 2006), "1K": ("VW Golf V / Jetta V (або Golf VI Plus / Scirocco)", 2003, 2014),
        "5K": ("VW Golf VI", 2008, 2013), "AU": ("VW Golf VII", 2012, 2020), "5G": ("VW Golf VII", 2012, 2020), "CD": ("VW Golf VIII", 2019, 2027),
        "3B": ("VW Passat B5", 1996, 2005), "3C": ("VW Passat B6 / B7 / CC", 2005, 2015), "3G": ("VW Passat B8", 2014, 2024),
        "9N": ("VW Polo IV", 2001, 2009), "6R": ("VW Polo V", 2009, 2017), "AW": ("VW Polo VI", 2017, 2027),
        "7L": ("VW Touareg I", 2002, 2010), "7P": ("VW Touareg II", 2010, 2018), "5N": ("VW Tiguan I", 2007, 2016), "AD": ("VW Tiguan II", 2016, 2024),
        "1T": ("VW Touran", 2003, 2015), "7H": ("VW Transporter T5", 2003, 2015), "7E": ("VW Transporter T5", 2009, 2015), "SG": ("VW Transporter T6", 2015, 2024),
        "2K": ("VW Caddy III", 2003, 2020), "1H": ("VW Golf III / Vento", 1991, 1999), "1G": ("VW Golf II / Jetta II", 1983, 1992),
        "31": ("VW Passat B3", 1988, 1993), "3A": ("VW Passat B4", 1993, 1997), "50": ("VW Corrado", 1988, 1995), "6N": ("VW Polo III", 1994, 2001),
        "1U": ("Škoda Octavia I", 1996, 2010), "1Z": ("Škoda Octavia II", 2004, 2013), "5E": ("Škoda Octavia III", 2012, 2020),
        "3U": ("Škoda Superb I", 2001, 2008), "3T": ("Škoda Superb II", 2008, 2015), "3V": ("Škoda Superb III", 2015, 2024),
        "6Y": ("Škoda Fabia I", 1999, 2007), "5J": ("Škoda Fabia II", 2007, 2014), "NJ": ("Škoda Fabia III", 2014, 2021),
        "8L": ("Audi A3 (8L)", 1996, 2003), "8P": ("Audi A3 (8P)", 2003, 2013), "8V": ("Audi A3 (8V)", 2012, 2020),
        "8D": ("Audi A4 B5", 1994, 2001), "8E": ("Audi A4 B6 / B7", 2000, 2008), "8K": ("Audi A4 B8", 2007, 2016), "8W": ("Audi A4 B9", 2015, 2024),
        "4A": ("Audi 100 / A6 C4", 1990, 1997), "4B": ("Audi A6 C5", 1997, 2005), "4F": ("Audi A6 C6", 2004, 2011), "4G": ("Audi A6 C7", 2011, 2018),
        "8C": ("Audi 80 B4", 1991, 1996), "89": ("Audi 80 B3", 1986, 1991), "44": ("Audi 100 / 200 C3", 1982, 1991),
        "4L": ("Audi Q7 (4L)", 2005, 2015), "8R": ("Audi Q5 (8R)", 2008, 2017),
        "1M": ("Seat Leon I / Toledo II", 1998, 2006), "1P": ("Seat Leon II", 2005, 2012), "5F": ("Seat Leon III", 2012, 2020),
        "6L": ("Seat Ibiza III", 2002, 2009), "6J": ("Seat Ibiza IV", 2008, 2017),
    ]
    static let vagWMI: Set<String> = ["WVW", "WV1", "WV2", "WVG", "WAU", "WUA", "TRU", "TMB", "VSS", "VWV", "LSV", "LFV"]

    /// Mercedes-Benz: 4–6 символи — номер шасі (тип кузова).
    static let mercedes: [String: (String, Int, Int)] = [
        "124": ("Mercedes E-клас W124", 1984, 1997), "201": ("Mercedes 190 W201", 1982, 1993), "126": ("Mercedes S-клас W126", 1979, 1991),
        "140": ("Mercedes S-клас W140", 1991, 1998), "220": ("Mercedes S-клас W220", 1998, 2005), "221": ("Mercedes S-клас W221", 2005, 2013),
        "202": ("Mercedes C-клас W202", 1993, 2001), "203": ("Mercedes C-клас W203", 2000, 2007), "204": ("Mercedes C-клас W204", 2007, 2014),
        "205": ("Mercedes C-клас W205", 2014, 2021), "210": ("Mercedes E-клас W210", 1995, 2003), "211": ("Mercedes E-клас W211", 2002, 2009),
        "212": ("Mercedes E-клас W212", 2009, 2016), "213": ("Mercedes E-клас W213", 2016, 2023), "123": ("Mercedes W123", 1976, 1986),
        "163": ("Mercedes ML W163", 1997, 2005), "164": ("Mercedes ML W164", 2005, 2011), "166": ("Mercedes ML / GLE W166", 2011, 2019),
        "168": ("Mercedes A-клас W168", 1997, 2004), "169": ("Mercedes A-клас W169", 2004, 2012), "245": ("Mercedes B-клас W245", 2005, 2011),
        "638": ("Mercedes Vito W638", 1996, 2003), "639": ("Mercedes Vito / Viano W639", 2003, 2014), "906": ("Mercedes Sprinter W906", 2006, 2018),
        "901": ("Mercedes Sprinter W901", 1995, 2006), "902": ("Mercedes Sprinter W902", 1995, 2006), "903": ("Mercedes Sprinter W903", 1995, 2006),
        "904": ("Mercedes Sprinter W904", 1995, 2006), "463": ("Mercedes G-клас W463", 1990, 2018), "129": ("Mercedes SL R129", 1989, 2001),
        "230": ("Mercedes SL R230", 2001, 2012), "170": ("Mercedes SLK R170", 1996, 2004), "171": ("Mercedes SLK R171", 2004, 2011),
        "208": ("Mercedes CLK C208", 1997, 2003), "209": ("Mercedes CLK C209", 2002, 2010), "251": ("Mercedes R-клас W251", 2005, 2013),
    ]
    static let mercedesWMI: Set<String> = ["WDB", "WDD", "WDC", "WDF", "WDA", "W1K", "W1N", "W1V"]

    public static func decode(_ vin: String) -> BrandVINInfo? {
        let c = Array(vin)
        guard c.count == 17 else { return nil }
        let wmi = String(c[0..<3])
        if vagWMI.contains(wmi), let m = vag[String(c[6..<8])] {
            return .init(model: m.0, years: m.1...m.2, detail: "Код моделі «\(String(c[6..<8]))» у 7–8 символах (формат концерну VW)")
        }
        if mercedesWMI.contains(wmi), let m = mercedes[String(c[3..<6])] {
            return .init(model: m.0, years: m.1...m.2, detail: "Номер шасі «\(String(c[3..<6]))» у 4–6 символах (формат Mercedes-Benz)")
        }
        return nil
    }
}

/// Регіон і стандарт, за яким складено VIN.
public enum VINRegion: Sendable, Hashable {
    case northAmerica, europe, asia, other

    public static func of(_ first: Character) -> VINRegion {
        switch first {
        case "1", "2", "3", "4", "5": return .northAmerica
        case "S", "T", "U", "V", "W", "X", "Y", "Z": return .europe
        case "J", "K", "L", "M", "N", "P", "R": return .asia
        default: return .other
        }
    }

    public var title: String {
        switch self {
        case .northAmerica: return "Північна Америка — стандарт FMVSS (США/Канада)"
        case .europe: return "Європа — стандарт ISO 3779"
        case .asia: return "Азія — стандарт ISO 3779"
        case .other: return "Інший регіон — стандарт ISO 3779"
        }
    }

    public var explanation: String {
        switch self {
        case .northAmerica:
            return "Строгі правила: 9-й символ — контрольна цифра, 10-й — модельний рік, 11-й — завод. Рік визначається точно."
        case .europe, .asia, .other:
            return "Обов'язкові лише код виробника (1–3) і серійний номер. Рік у 10-му символі виробники ставлять на власний розсуд — багато хто його не кодує, особливо в старих авто."
        }
    }
}
