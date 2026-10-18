import Foundation

/// Віртуальний адаптер з «автомобілем»: щоб подивитися програму без машини.
/// Яке саме авто і які в нього поломки — задає `DemoScenario`.
public final class DemoTransport: OBDTransport, @unchecked Sendable {
    public var onReceive: ((Data) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    public var displayName: String { "Демо: \(scenario.car)" }

    public let scenario: DemoScenario
    private let queue = DispatchQueue(label: "demo.elm327")
    private var echo = true
    private var spaces = true
    private var input = ""
    private let start: Date
    private var stored: [String]
    private var pending: [String]
    private var cleared = false
    private var distanceSinceClear = 1840
    private var searched = false
    /// Протокол, вибраний командою ATSP («0» — автопошук).
    private var selectedProtocol = "0"

    /// - Parameters:
    ///   - scenario: яке авто імітувати.
    ///   - startOffset: «скільки секунд авто вже працює» (для тестів).
    public init(scenario: DemoScenario = .default, startOffset: TimeInterval = 0) {
        self.scenario = scenario
        stored = scenario.stored
        pending = scenario.pending
        start = Date().addingTimeInterval(-startOffset)
    }

    public func open() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    public func close() {}

    public func send(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        queue.async { [weak self] in self?.consume(text) }
    }

    private func consume(_ text: String) {
        input += text
        while let r = input.firstIndex(of: "\r") {
            let cmd = String(input[..<r]).trimmingCharacters(in: .whitespaces).uppercased()
            input = String(input[input.index(after: r)...])
            let reply = respond(to: cmd)
            var out = echo ? cmd + "\r" : ""
            out += reply + "\r\r>"
            let payload = Data(out.utf8)
            // Старі протоколи (K-Line) повільніші за CAN
            let base = scenario.isCAN ? 0.03 : 0.07
            let delay = cmd == "ATZ" ? 0.4 : (cmd == "0100" && !searched ? 0.8 : base)
            if cmd == "0100" { searched = true }
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.onReceive?(payload)
            }
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: spaces ? " " : "")
    }

    static func codeBytes(_ code: String) -> [UInt8] {
        let c = Array(code)
        let letter: UInt8 = ["P": 0, "C": 1, "B": 2, "U": 3][c[0]] ?? 0
        let d1 = UInt8(String(c[1]))!
        let d2 = UInt8(String(c[2]), radix: 16)!
        let b = UInt8(String(c[3...4]), radix: 16)!
        return [(letter << 6) | (d1 << 4) | d2, b]
    }

    /// Бітова маска підтримуваних PID для запиту 01 00/20/40/…
    func supportedMask(offset: UInt8) -> [UInt8]? {
        let pids = scenario.pids
        let inRange = pids.filter { $0 > offset && Int($0) <= Int(offset) + 32 }
        let hasMore = pids.contains { Int($0) > Int(offset) + 32 }
        if inRange.isEmpty && !hasMore && offset != 0 { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        for p in inRange {
            let i = Int(p - offset - 1)
            bytes[i / 8] |= 0x80 >> (i % 8)
        }
        if hasMore { bytes[3] |= 0x01 }
        return bytes
    }

    private func respond(to cmd: String) -> String {
        if cmd.hasPrefix("AT") {
            switch cmd {
            case "ATZ", "ATWS":
                echo = true; spaces = true; selectedProtocol = "0"
                return scenario.failsAutoSearch ? "\rELM327 v2.1" : "\rELM327 v1.5 (демо)"
            case "ATE0": echo = false; return "OK"
            case "ATE1": echo = true; return "OK"
            case "ATS0": spaces = false; return "OK"
            case "ATS1": spaces = true; return "OK"
            case "ATDPN": return selectedProtocol == "0" ? "A" + scenario.protocolNumber : selectedProtocol
            case "ATRV": return String(format: "%.1fV", value(0x42) ?? 14.1)
            case "ATI": return scenario.failsAutoSearch ? "ELM327 v2.1" : "ELM327 v1.5 (демо)"
            default:
                if cmd.hasPrefix("ATSP") || cmd.hasPrefix("ATTP") {
                    selectedProtocol = String(cmd.dropFirst(4).prefix(1))
                    if selectedProtocol.isEmpty { selectedProtocol = "0" }
                }
                return "OK"
            }
        }
        switch cmd {
        case "0101":
            let count = UInt8(min(127, stored.count))
            let mil: UInt8 = stored.isEmpty ? 0 : 0x80
            let diesel: UInt8 = scenario.isDiesel ? 0x08 : 0
            let fuelIncomplete: UInt8 = (!stored.isEmpty || cleared) ? 0x20 : 0
            let d: UInt8 = cleared ? scenario.monitorsC : (stored.isEmpty && pending.isEmpty ? 0 : scenario.monitorsIncomplete)
            return hex([0x41, 0x01, mil | count, 0x07 | diesel | fuelIncomplete, scenario.monitorsC, d])
        case "03": return dtcReply(0x43, stored)
        case "07": return dtcReply(0x47, pending)
        case "0A": return scenario.supportsPermanent ? dtcReply(0x4A, scenario.permanent) : "NO DATA"
        case "04":
            stored = []; pending = []; distanceSinceClear = 0; cleared = true
            return "44"
        case "0902":
            guard let v = scenario.vin else { return "NO DATA" }
            return vinReply(v)
        default:
            break
        }
        // Кілька параметрів одним запитом (лише CAN, до 6 штук)
        if cmd.count > 4, cmd.count <= 14, cmd.count % 2 == 0, cmd.hasPrefix("01"), scenario.isCAN {
            var bytes: [UInt8] = [0x41]
            var i = cmd.index(cmd.startIndex, offsetBy: 2)
            while i < cmd.endIndex {
                let j = cmd.index(i, offsetBy: 2)
                if let pid = UInt8(cmd[i..<j], radix: 16), pid % 0x20 != 0, scenario.pids.contains(pid), let raw = rawBytes(pid) {
                    bytes += [pid] + raw
                }
                i = j
            }
            return bytes.count > 1 ? canFrames(bytes) : "NO DATA"
        }
        if cmd.count == 4, cmd.hasPrefix("01"), let pid = UInt8(cmd.suffix(2), radix: 16) {
            if pid == 0 {
                // Імітація капризного клону: автопошук не працює, ручний вибір — так
                if selectedProtocol == "0" && scenario.failsAutoSearch { return "SEARCHING...\rUNABLE TO CONNECT" }
                if selectedProtocol != "0" && selectedProtocol != scenario.protocolNumber { return "UNABLE TO CONNECT" }
            }
            if pid % 0x20 == 0 {
                guard let mask = supportedMask(offset: pid) else { return "NO DATA" }
                let line = hex([0x41, pid] + mask)
                // Старі протоколи спершу «будять» шину
                return (pid == 0 && !scenario.isCAN) ? "SEARCHING...\rBUS INIT: ...OK\r" + line : line
            }
            guard scenario.pids.contains(pid), let raw = rawBytes(pid) else { return "NO DATA" }
            return hex([0x41, pid] + raw)
        }
        return "?"
    }

    private func dtcReply(_ mode: UInt8, _ codes: [String]) -> String {
        if scenario.isCAN {
            return hex([mode, UInt8(codes.count)] + codes.flatMap(Self.codeBytes))
        }
        // K-Line: по три коди в рядку, без лічильника, доповнено нулями
        var all = codes.flatMap(Self.codeBytes)
        if all.isEmpty { all = [0, 0] }
        while all.count % 6 != 0 { all += [0, 0] }
        var lines: [String] = []
        var i = 0
        while i < all.count {
            lines.append(hex([mode] + Array(all[i..<i + 6])))
            i += 6
        }
        return lines.joined(separator: "\r")
    }

    private func vinReply(_ vin: String) -> String {
        canFrames([0x49, 0x02, 0x01] + Array(vin.utf8))
    }

    /// Відповідь у форматі CAN: до 7 байтів — один рядок, більше — кадри «0: …», «1: …».
    private func canFrames(_ bytes: [UInt8]) -> String {
        if bytes.count <= 7 { return hex(bytes) }
        var lines = [String(format: "%03X", bytes.count)]
        var i = 0, n = 0
        while i < bytes.count {
            let size = n == 0 ? 6 : 7
            let part = Array(bytes[i..<min(i + size, bytes.count)])
            lines.append("\(n): " + hex(part))
            i += size; n += 1
        }
        return lines.joined(separator: "\r")
    }

    // MARK: Імітація двигуна

    private var t: Double { Date().timeIntervalSince(start) }

    // Ручна «педаль газу» для демо: поки вона натиснута, двигун слухається її, а не автоматичного циклу.
    private let pedalLock = NSLock()
    private var pedalTarget: Double?
    private var pedalReleasedAt: Date?
    private var pedalState: Double = 0

    /// Натиснути педаль (0…1) або відпустити (nil). Після відпускання двигун якийсь час стоїть на холостому.
    public func setPedal(_ value: Double?) {
        pedalLock.lock()
        if let v = value { pedalTarget = max(0, min(1, v)); pedalReleasedAt = nil }
        else { pedalTarget = 0; pedalReleasedAt = Date() }
        pedalLock.unlock()
    }
    private func noise(_ amp: Double) -> Double { amp <= 0 ? 0 : Double.random(in: -amp...amp) }
    /// Плавний «шум», як у справжніх датчиків: значення повільно дрейфує, а не стрибає.
    private var drift: [UInt8: Double] = [:]
    private func wander(_ key: UInt8, _ amp: Double) -> Double {
        guard amp > 0 else { return 0 }
        let prev = drift[key] ?? 0
        let next = max(-amp, min(amp, prev * 0.9 + Double.random(in: -amp...amp) * 0.3))
        drift[key] = next
        return next
    }
    // Перші ~20 с — холостий хід, далі розгін під навантаженням, і так по колу.
    private var autoDrive: Double { max(0, sin(t / 7 + 3.3)) }
    private var drive: Double {
        pedalLock.lock(); defer { pedalLock.unlock() }
        guard let target = pedalTarget else { return autoDrive }
        // Двигун має інерцію: оберти наздоганяють педаль плавно
        pedalState += (target - pedalState) * 0.18
        if target == 0, let r = pedalReleasedAt, Date().timeIntervalSince(r) > 12, pedalState < 0.02 {
            pedalTarget = nil      // через 12 с після відпускання повертаємося до автоматичного циклу
        }
        return pedalState
    }

    private func value(_ pid: UInt8) -> Double? {
        let m = scenario.model
        let d = drive
        switch pid {
        case 0x0C: return max(0, m.idleRPM + d * (m.driveRPM - m.idleRPM) + noise(m.rpmJitter))
        case 0x05: return m.coolantOverride ?? min(m.coolantTarget, m.coolantStart + t / 6)
        case 0x04: return 21 + d * 62 + wander(0x04, 1.5)
        case 0x43: return 18 + d * 55 + wander(0x43, 1.5)
        case 0x0E: return 9 + d * 14 + wander(0x0E, 1.0)
        case 0x0D: return d * 92
        case 0x06: return m.stft + wander(0x06, 2.5)
        case 0x07: return m.ltft
        case 0x0B: return m.mapIdle + d * (m.mapPeak - m.mapIdle) + wander(0x0B, 1.5)
        case 0x33: return 98
        case 0x0F: return m.intakeOverride ?? (31 + wander(0x0F, 0.4))
        case 0x10: return max(0, m.mafIdle + d * m.mafDrive + wander(0x10, 0.15))
        case 0x11: return 14 + d * 55 + wander(0x11, 0.3)
        case 0x14:
            let s = sin(t * 5.2)
            switch m.o2 {
            case .normal: return 0.45 + s * 0.38 + noise(0.02)
            case .lean: return 0.12 + (s > 0.6 ? 0.36 : 0.04) + noise(0.02)
            case .rich: return 0.80 + (s < -0.6 ? -0.46 : 0.03) + noise(0.02)
            case .absent: return nil
            }
        case 0x15:
            if m.o2 == .absent { return nil }
            switch m.o2Down {
            case .steady: return 0.66 + noise(0.02)
            case .mirror: return 0.45 + sin(t * 5.2 + 0.5) * 0.36 + noise(0.02)
            }
        case 0x1F: return t + 900
        case 0x21: return stored.isEmpty ? 0 : 412
        case 0x23:
            guard let idle = m.railIdle else { return nil }
            return idle + d * (m.railDrive - idle) + noise(4)
        case 0x2C: return scenario.isDiesel ? max(0, 32 - d * 30) : nil
        case 0x2D: return m.egrError.map { $0 + wander(0x2D, 2) }
        case 0x2F: return m.fuelLevel
        case 0x31: return Double(distanceSinceClear)
        case 0x42: return m.voltage + wander(0x42, 0.05)
        case 0x44: return 1.0
        case 0x45: return 10 + d * 50
        case 0x46: return 12
        case 0x49: return 15 + d * 50
        case 0x5C: return min(96, 62 + t / 5)
        case 0x24:
            switch m.o2 {
            case .lean: return 1.07 + noise(0.01)
            case .rich: return 0.93 + noise(0.01)
            case .normal: return 1.0 + noise(0.012)
            case .absent: return nil
            }
        case 0x2E: return 18 + d * 20
        case 0x30: return 37
        case 0x47: return 16 + d * 55
        case 0x4A: return 8 + d * 25
        case 0x4D: return stored.isEmpty ? 0 : 845
        case 0x4E: return Double(distanceSinceClear) * 1.8
        case 0x5A: return 15 + d * 50
        case 0x61: return 8 + d * 70
        case 0x62: return 6 + d * 68
        case 0x63: return scenario.isDiesel ? 320 : 250
        case 0x1C: return scenario.id == "camry" ? 7 : 6
        case 0x51: return scenario.isDiesel ? 4 : 1
        case 0x55: return 0.8 + wander(0x55, 0.6)
        case 0x56: return m.o2Down == .mirror ? 9.4 : 1.6
        case 0x67: return m.coolantOverride ?? min(m.coolantTarget, m.coolantStart + t / 6) + wander(0x67, 0.3)
        case 0x6F: return 98 + wander(0x6F, 0.4) - d * 6
        case 0x73: return 101 + d * (m.mapPeak - 90) * 0.9 + wander(0x73, 0.8)
        case 0x74: return 22000 + d * 140000 + wander(0x74, 900)
        case 0x77: return 28 + d * 18 + wander(0x77, 0.4)
        case 0x78: return 260 + d * 380 + wander(0x78, 4)
        case 0x7A: return (scenario.stored.contains("P2463") ? 9.5 : 1.2) + d * 6 + wander(0x7A, 0.15)
        case 0x7C: return 230 + d * 290 + wander(0x7C, 3)
        case 0x7F: return 6_420_000 + t
        case 0x8E: return 14 + wander(0x8E, 0.5)
        case 0xA6: return 184_532.4 + t / 120
        default: return nil
        }
    }

    private func rawBytes(_ pid: UInt8) -> [UInt8]? {
        guard let v = value(pid) else { return nil }
        func u8(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x.rounded()))) }
        func u16(_ x: Double) -> [UInt8] {
            let i = Int(max(0, min(65535, x.rounded())))
            return [UInt8(i >> 8), UInt8(i & 0xFF)]
        }
        switch pid {
        case 0x0C: return u16(v * 4)
        case 0x05, 0x0F, 0x46, 0x5C: return [u8(v + 40)]
        case 0x04, 0x11, 0x2C, 0x2E, 0x2F, 0x45, 0x47, 0x49, 0x4A, 0x5A: return [u8(v * 255 / 100)]
        case 0x30: return [u8(v)]
        case 0x4D, 0x4E, 0x63: return u16(v)
        case 0x61, 0x62: return [u8(v + 125)]
        case 0x24: return u16(v * 65536 / 2) + [0x80, 0x00]
        case 0x55, 0x56: return [u8(v * 128 / 100 + 128), 0x80]
        case 0x67: return [0x01, u8(v + 40), 0x00]
        case 0x6F: return [0x01, u8(v), 0x00]
        case 0x73: return [0x01] + u16(v * 100) + [0, 0]
        case 0x74: return [0x01] + u16(v / 10) + [0, 0]
        case 0x77: return [0x01, u8(v + 40), 0, 0, 0]
        case 0x78: return [0x01] + u16((v + 40) * 10) + [0, 0, 0, 0, 0, 0]
        case 0x7A: return [0x01] + u16(v * 100) + [0, 0, 0, 0]
        case 0x7C: return [0x01] + u16((v + 40) * 10) + [0, 0, 0, 0, 0, 0]
        case 0x7F:
            let s = Int(v)
            return [0x01, UInt8((s >> 24) & 0xFF), UInt8((s >> 16) & 0xFF), UInt8((s >> 8) & 0xFF), UInt8(s & 0xFF)] + [UInt8](repeating: 0, count: 8)
        case 0x8E: return [u8(v + 125)]
        case 0x1C, 0x51: return [u8(v)]
        case 0xA6:
            let x = Int(v * 10)
            return [UInt8((x >> 24) & 0xFF), UInt8((x >> 16) & 0xFF), UInt8((x >> 8) & 0xFF), UInt8(x & 0xFF)]
        case 0x43: return u16(v * 255 / 100)
        case 0x0E: return [u8((v + 64) * 2)]
        case 0x0D, 0x0B, 0x33: return [u8(v)]
        case 0x06, 0x07, 0x2D: return [u8(v * 128 / 100 + 128)]
        case 0x10: return u16(v * 100)
        case 0x14, 0x15: return [u8(v * 200), 0xFF]
        case 0x1F, 0x21, 0x31: return u16(v)
        case 0x23: return u16(v * 10)
        case 0x42: return u16(v * 1000)
        case 0x44: return u16(v * 65536 / 2)
        default: return nil
        }
    }
}
