import Foundation

/// Тип збереження помилки в блоці.
public enum DTCKind: String, Codable, CaseIterable, Sendable {
    case stored      // режим 03 — підтверджені
    case pending     // режим 07 — очікувані (з'явилися в останньому циклі)
    case permanent   // режим 0A — постійні (стираються лише після самоперевірки)

    public var title: String {
        switch self {
        case .stored: return "Активна"
        case .pending: return "Очікувана"
        case .permanent: return "Постійна"
        }
    }

    public var explanation: String {
        switch self {
        case .stored: return "Блок підтвердив несправність і, можливо, засвітив лампу Check Engine."
        case .pending: return "Несправність помічена в останній поїздці, але ще не підтверджена. Якщо повториться — стане активною."
        case .permanent: return "Записана в блоці назавжди, поки система сама не переконається, що несправність зникла. Кнопкою не стирається."
        }
    }
}

/// Код несправності (напр. P0171).
public struct DTC: Hashable, Identifiable, Sendable {
    public let code: String
    public let kind: DTCKind
    public var id: String { code + "-" + kind.rawValue }

    public init(code: String, kind: DTCKind) {
        self.code = code.uppercased()
        self.kind = kind
    }

    /// Система, до якої належить код (перша літера).
    public var systemTitle: String {
        switch code.first {
        case "P": return "Двигун і трансмісія"
        case "C": return "Шасі (ABS, підвіска, кермо)"
        case "B": return "Кузов (подушки, клімат, світло)"
        case "U": return "Мережа зв'язку між блоками"
        default: return "Невідома система"
        }
    }

    /// Чи є код заводським (специфічним для марки), а не загальним стандартом SAE.
    public var isManufacturerSpecific: Bool {
        let chars = Array(code)
        guard chars.count == 5 else { return false }
        switch chars[0] {
        case "P":
            // P1xxx і P3000–P33xx — заводські; P0, P2, P34–P39 — загальні.
            return chars[1] == "1" || (chars[1] == "3" && "0123".contains(chars[2]))
        default:
            return chars[1] == "1" || chars[1] == "2"
        }
    }

    /// Декодує два байти у код (SAE J2012). Повертає nil для «порожнього» 0000.
    public static func decode(_ a: UInt8, _ b: UInt8, kind: DTCKind) -> DTC? {
        if a == 0 && b == 0 { return nil }
        let letters: [Character] = ["P", "C", "B", "U"]
        let letter = letters[Int(a >> 6)]
        let d1 = (a >> 4) & 0x03
        let d2 = a & 0x0F
        let code = String(letter) + String(d1) + String(d2, radix: 16).uppercased()
            + String(format: "%02X", b)
        return DTC(code: code, kind: kind)
    }

    /// Розбирає байти відповіді на режими 03/07/0A.
    /// - Parameter isCAN: для CAN перший байт — кількість кодів.
    public static func parse(payloads: [[UInt8]], isCAN: Bool, kind: DTCKind) -> [DTC] {
        var result: [DTC] = []
        for var p in payloads {
            if isCAN, !p.isEmpty {
                let count = Int(p[0])
                p.removeFirst()
                if count * 2 <= p.count { p = Array(p.prefix(count * 2)) }
            } else if p.count % 2 == 1 {
                // невідомий протокол: непарна довжина означає байт кількості спереду
                p.removeFirst()
            }
            var i = 0
            while i + 1 < p.count {
                if let dtc = decode(p[i], p[i + 1], kind: kind), !result.contains(dtc) {
                    result.append(dtc)
                }
                i += 2
            }
        }
        return result
    }
}
