import Foundation

/// Відомості про підключення, отримані під час ініціалізації.
public struct ConnectionInfo: Sendable {
    public var adapterVersion: String = ""
    public var protocolName: String = ""
    public var protocolNumber: String = ""
    public var isCAN: Bool = true
}

/// Високорівневі операції OBD2 поверх адаптера ELM327.
public final class OBDService: @unchecked Sendable {
    public let session: ELM327Session
    public private(set) var info = ConnectionInfo()
    public private(set) var supportedPIDs: Set<UInt8> = []

    public init(session: ELM327Session) {
        self.session = session
    }

    // MARK: Ініціалізація

    /// Скидає адаптер, налаштовує формат відповідей і встановлює зв'язок з авто.
    public func initialize(progress: ((String) -> Void)? = nil) async throws {
        progress?("Скидання адаптера…")
        // Після ATZ адаптер перезавантажується, відповідь може йти довше.
        let reset = try await session.command("ATZ", timeout: 6)
        info.adapterVersion = reset
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.uppercased().contains("ELM") || $0.uppercased().contains("STN") || $0.uppercased().contains("OBD") }
            ?? reset.trimmingCharacters(in: .whitespacesAndNewlines)

        progress?("Налаштування адаптера…")
        for cmd in ["ATE0", "ATL0", "ATS1", "ATH0", "ATAT1"] {
            _ = try? await session.command(cmd)
        }
        // Заводське значення часу очікування; деякі старі авто відповідають повільно.
        _ = try? await session.command("ATST64")

        progress?("Пошук протоколу авто…")
        _ = try await session.command("ATSP0")
        // Перший запит запускає автоматичний пошук протоколу — може тривати до ~10 с.
        let first = try await session.command("0100", timeout: 15)
        do {
            let p = try ResponseParser.payload(from: first, mode: 0x01, pid: 0x00)
            supportedPIDs = Self.decodeSupported(p, offset: 0x00)
        } catch let e as AdapterError {
            throw e == .noData ? AdapterError.unableToConnect : e
        }

        let dpn = (try? await session.command("ATDPN")) ?? ""
        var num = dpn.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if num.count == 2, num.hasPrefix("A") { num.removeFirst() }  // «A6» = автовибір, протокол 6
        info.protocolNumber = num
        info.isCAN = ["6", "7", "8", "9", "B", "C"].contains(num)
        info.protocolName = Self.protocolName(num)

        progress?("Читання списку підтримуваних параметрів…")
        var offset: UInt8 = 0x20
        while supportedPIDs.contains(offset), offset < 0xE0 {
            let cmd = String(format: "01%02X", offset)
            guard let raw = try? await session.command(cmd),
                  let p = try? ResponseParser.payload(from: raw, mode: 0x01, pid: offset) else { break }
            supportedPIDs.formUnion(Self.decodeSupported(p, offset: offset))
            offset &+= 0x20
        }
        session.info("Протокол: \(info.protocolName). Підтримуваних параметрів: \(supportedPIDs.count)")
    }

    static func decodeSupported(_ bytes: [UInt8], offset: UInt8) -> Set<UInt8> {
        var set = Set<UInt8>()
        for (i, b) in bytes.prefix(4).enumerated() {
            for bit in 0..<8 where b & (0x80 >> bit) != 0 {
                set.insert(offset &+ UInt8(i * 8 + bit + 1))
            }
        }
        return set
    }

    static func protocolName(_ n: String) -> String {
        switch n {
        case "1": return "SAE J1850 PWM (Ford)"
        case "2": return "SAE J1850 VPW (GM)"
        case "3": return "ISO 9141-2"
        case "4": return "ISO 14230-4 KWP (повільна ініціалізація)"
        case "5": return "ISO 14230-4 KWP (швидка ініціалізація)"
        case "6": return "CAN 11 біт, 500 кбіт/с"
        case "7": return "CAN 29 біт, 500 кбіт/с"
        case "8": return "CAN 11 біт, 250 кбіт/с"
        case "9": return "CAN 29 біт, 250 кбіт/с"
        case "B", "C": return "CAN (користувацький)"
        default: return n.isEmpty ? "Невідомий" : "Протокол \(n)"
        }
    }

    // MARK: Дані

    public func isSupported(_ pid: UInt8) -> Bool {
        supportedPIDs.isEmpty || supportedPIDs.contains(pid)
    }

    /// Читає один параметр поточних даних. nil — авто не відповіло.
    public func read(_ def: PIDDefinition) async throws -> Double? {
        let raw = try await session.command(def.hexCode)
        do {
            let data = try ResponseParser.payload(from: raw, mode: 0x01, pid: def.pid)
            return def.decode(data)
        } catch AdapterError.noData {
            return nil
        }
    }

    public func monitorStatus() async throws -> MonitorStatus? {
        let raw = try await session.command("0101")
        let data = try ResponseParser.payload(from: raw, mode: 0x01, pid: 0x01)
        return MonitorStatus(bytes: data)
    }

    public func readDTCs(kind: DTCKind) async throws -> [DTC] {
        let mode: UInt8
        switch kind {
        case .stored: mode = 0x03
        case .pending: mode = 0x07
        case .permanent: mode = 0x0A
        }
        let raw = try await session.command(String(format: "%02X", mode), timeout: 6)
        do {
            let payloads = try ResponseParser.allPayloads(from: raw, mode: mode)
            return DTC.parse(payloads: payloads, isCAN: info.isCAN, kind: kind)
        } catch AdapterError.noData {
            return []
        }
    }

    /// Стирає помилки та скидає монітори готовності (режим 04).
    public func clearDTCs() async throws {
        let raw = try await session.command("04", timeout: 8)
        let lines = ResponseParser.cleanLines(raw)
        if let e = ResponseParser.detectError(lines) { throw e }
        guard lines.contains(where: { $0.replacingOccurrences(of: " ", with: "").hasPrefix("44") }) else {
            throw AdapterError.transport("Блок не підтвердив стирання. Перевірте, що запалювання увімкнене, а двигун заглушений.")
        }
    }

    public func readVIN() async throws -> String? {
        let raw = try await session.command("0902", timeout: 6)
        let payloads = try ResponseParser.allPayloads(from: raw, mode: 0x09)
        var bytes: [UInt8] = []
        for p in payloads {
            guard p.first == 0x02 else { continue }
            // Перший байт — PID, далі (для CAN) номер елемента, потім ASCII.
            bytes += p.dropFirst()
        }
        let text = String(bytes.filter { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
            .map { Character(UnicodeScalar($0)) })
        guard text.count >= 17 else { return nil }
        return String(text.suffix(17))
    }
}
