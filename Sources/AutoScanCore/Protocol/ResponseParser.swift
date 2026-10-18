import Foundation

/// Помилки, які повертає адаптер ELM327 замість даних.
public enum AdapterError: Error, Equatable, CustomStringConvertible {
    case noData
    case unableToConnect
    case canError
    case busError
    case stopped
    case bufferFull
    case unknownCommand
    case timeout
    case notConnected
    case transport(String)

    public var description: String {
        switch self {
        case .noData: return "Блок не відповів (NO DATA)"
        case .unableToConnect: return "Адаптер не зміг з'єднатися з авто. Перевірте, чи увімкнене запалювання."
        case .canError: return "Помилка шини CAN. Перевірте підключення адаптера."
        case .busError: return "Помилка шини даних авто."
        case .stopped: return "Запит перервано."
        case .bufferFull: return "Буфер адаптера переповнений."
        case .unknownCommand: return "Адаптер не зрозумів команду."
        case .timeout: return "Адаптер не відповів вчасно."
        case .notConnected: return "Адаптер не підключено."
        case .transport(let m): return m
        }
    }
}

/// Перетворює текстову відповідь ELM327 на набір повідомлень (масивів байтів).
public enum ResponseParser {

    /// Прибирає службові рядки та повертає «чисті» рядки відповіді.
    public static func cleanLines(_ raw: String) -> [String] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: ">", with: "")
        var result: [String] = []
        for var line in normalized.components(separatedBy: "\n") {
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("SEARCHING") { continue }
            if upper.hasPrefix("BUS INIT") {
                // «BUS INIT: ...OK» інколи йде в одному рядку з даними
                if let r = upper.range(of: "OK") {
                    let rest = upper[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { result.append(rest) }
                }
                continue
            }
            result.append(upper)
        }
        return result
    }

    /// Шукає в рядках відповіді відому помилку адаптера.
    public static func detectError(_ lines: [String]) -> AdapterError? {
        let joined = lines.joined(separator: " ")
        if joined.contains("NO DATA") { return .noData }
        if joined.contains("UNABLE TO CONNECT") { return .unableToConnect }
        if joined.contains("CAN ERROR") { return .canError }
        if joined.contains("BUS ERROR") || joined.contains("BUS BUSY") || joined.contains("FB ERROR")
            || joined.contains("DATA ERROR") || joined.contains("LV RESET") {
            return .busError
        }
        if joined.contains("STOPPED") { return .stopped }
        if joined.contains("BUFFER FULL") { return .bufferFull }
        if lines.count == 1 && lines[0] == "?" { return .unknownCommand }
        return nil
    }

    static func hexBytes(_ s: String) -> [UInt8]? {
        let hex = s.filter { !$0.isWhitespace }
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return bytes
    }

    static func isHexLine(_ s: String) -> Bool {
        let allowed = Set("0123456789ABCDEF ")
        return !s.isEmpty && s.allSatisfy { allowed.contains($0) }
    }

    /// Розбирає відповідь (заголовки вимкнені: ATH0) на окремі повідомлення.
    /// Підтримує багатокадрові відповіді CAN у форматі «0: ..», «1: ..».
    public static func messages(from raw: String) throws -> [[UInt8]] {
        let lines = cleanLines(raw)
        if let err = detectError(lines) { throw err }

        var messages: [[UInt8]] = []
        var current: [UInt8]? = nil

        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let indexPart = line[..<colon].trimmingCharacters(in: .whitespaces)
                let dataPart = String(line[line.index(after: colon)...])
                guard isHexLine(indexPart), let bytes = hexBytes(dataPart) else { continue }
                if indexPart == "0" {
                    if let c = current { messages.append(c) }
                    current = bytes
                } else {
                    current = (current ?? []) + bytes
                }
                continue
            }
            guard isHexLine(line) else { continue }
            let compact = line.filter { !$0.isWhitespace }
            // Рядок довжини багатокадрової відповіді (напр. «014») — пропускаємо.
            if compact.count <= 3 { continue }
            if let c = current { messages.append(c); current = nil }
            if let bytes = hexBytes(compact) { messages.append(bytes) }
        }
        if let c = current { messages.append(c) }
        return messages
    }

    /// Знаходить повідомлення-відповідь на режим `mode` (+0x40), опційно з PID.
    /// Повертає байти даних після заголовка (режим і PID відкинуто).
    public static func payload(from raw: String, mode: UInt8, pid: UInt8? = nil) throws -> [UInt8] {
        let msgs = try messages(from: raw)
        let answer = mode &+ 0x40
        for m in msgs {
            guard let start = m.firstIndex(of: answer) else { continue }
            var i = start + 1
            if let pid = pid {
                guard i < m.count, m[i] == pid else { continue }
                i += 1
            }
            return Array(m[i...])
        }
        throw AdapterError.noData
    }

    /// Усі відповіді на режим (від різних блоків або кадрів), без байта режиму.
    public static func allPayloads(from raw: String, mode: UInt8) throws -> [[UInt8]] {
        let msgs = try messages(from: raw)
        let answer = mode &+ 0x40
        return msgs.compactMap { m in
            guard let start = m.firstIndex(of: answer) else { return nil }
            return Array(m[(start + 1)...])
        }
    }
}
