import Foundation

/// Віртуальний адаптер з «автомобілем»: щоб подивитися програму без машини.
/// Імітує бензиновий турбодвигун з бідною сумішшю, недостатнім наддувом
/// і пропусками запалювання в 1-му циліндрі.
public final class DemoTransport: OBDTransport, @unchecked Sendable {
    public var onReceive: ((Data) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    public var displayName: String { "Демо-авто" }

    private let queue = DispatchQueue(label: "demo.elm327")
    private var echo = true
    private var spaces = true
    private var input = ""
    private let start = Date()
    private var stored: [String] = ["P0171", "P0299"]
    private var pending: [String] = ["P0301"]
    private var distanceSinceClear = 1840

    public init() {}

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
            let delay = cmd == "ATZ" ? 0.4 : (cmd == "0100" ? 0.6 : 0.03)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.onReceive?(payload)
            }
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: spaces ? " " : "")
    }

    private func codeBytes(_ code: String) -> [UInt8] {
        let c = Array(code)
        let letter: UInt8 = ["P": 0, "C": 1, "B": 2, "U": 3][c[0]] ?? 0
        let d1 = UInt8(String(c[1]))!
        let d2 = UInt8(String(c[2]), radix: 16)!
        let b = UInt8(String(c[3...4]), radix: 16)!
        return [(letter << 6) | (d1 << 4) | d2, b]
    }

    private func respond(to cmd: String) -> String {
        if cmd.hasPrefix("AT") {
            switch cmd {
            case "ATZ", "ATWS": echo = true; spaces = true; return "\rELM327 v1.5 (демо)"
            case "ATE0": echo = false; return "OK"
            case "ATE1": echo = true; return "OK"
            case "ATS0": spaces = false; return "OK"
            case "ATS1": spaces = true; return "OK"
            case "ATDPN": return "A6"
            case "ATDP": return "AUTO, ISO 15765-4 (CAN 11/500)"
            case "ATRV": return String(format: "%.1fV", value(0x42) ?? 14.1)
            case "ATI": return "ELM327 v1.5 (демо)"
            default: return "OK"
            }
        }
        switch cmd {
        case "0100": return hex([0x41, 0x00, 0xBE, 0x3F, 0xB8, 0x13])
        case "0120": return hex([0x41, 0x20, 0x80, 0x02, 0xA0, 0x01])
        case "0140": return hex([0x41, 0x40, 0x7C, 0x80, 0x00, 0x10])
        case "0160": return "NO DATA"
        case "0101":
            let count = UInt8(stored.count)
            let mil: UInt8 = stored.isEmpty ? 0 : 0x80
            // B: монітори пропусків, палива, компонентів підтримуються, паливна незавершена
            // C/D: каталізатор, EVAP, лямбда, підігрів лямбди підтримуються; EVAP незавершений
            return hex([0x41, 0x01, mil | count, 0x27, 0x65, stored.isEmpty ? 0x65 : 0x04])
        case "03": return dtcReply(0x43, stored)
        case "07": return dtcReply(0x47, pending)
        case "0A": return dtcReply(0x4A, [])
        case "04":
            stored = []; pending = []; distanceSinceClear = 0
            return "44"
        case "0902":
            let vin = Array("WVWZZZ3CZEE123456".utf8)
            let bytes: [UInt8] = [0x49, 0x02, 0x01] + vin
            // Багатокадрова відповідь CAN
            var lines = ["014"]
            var i = 0, n = 0
            while i < bytes.count {
                let size = n == 0 ? 6 : 7
                let part = Array(bytes[i..<min(i + size, bytes.count)])
                lines.append("\(n): " + hex(part))
                i += size; n += 1
            }
            return lines.joined(separator: "\r")
        default:
            break
        }
        if cmd.count == 4, cmd.hasPrefix("01"), let pid = UInt8(cmd.suffix(2), radix: 16) {
            guard let raw = rawBytes(pid) else { return "NO DATA" }
            return hex([0x41, pid] + raw)
        }
        return "?"
    }

    private func dtcReply(_ mode: UInt8, _ codes: [String]) -> String {
        hex([mode, UInt8(codes.count)] + codes.flatMap(codeBytes))
    }

    // MARK: Імітація двигуна

    private var t: Double { Date().timeIntervalSince(start) }
    private func noise(_ amp: Double) -> Double { Double.random(in: -amp...amp) }
    private var drive: Double { max(0, sin(t / 7)) }

    private func value(_ pid: UInt8) -> Double? {
        let d = drive
        let misfireJitter = pending.contains("P0301") ? noise(45) : noise(8)
        let lean = stored.contains("P0171")
        let underboost = stored.contains("P0299")
        switch pid {
        case 0x0C: return 790 + d * 2600 + misfireJitter
        case 0x05: return min(92, 68 + t / 6)
        case 0x04: return 21 + d * 62 + noise(1.5)
        case 0x43: return 18 + d * 55 + noise(1.5)
        case 0x0E: return 9 + d * 14 + noise(1.0)
        case 0x0D: return d * 92
        case 0x06: return (lean ? 6.2 : 0.8) + noise(2.5)
        case 0x07: return lean ? 17.9 : 1.6
        case 0x0B: return 33 + d * (underboost ? 98 : 150) + noise(1.5)
        case 0x33: return 98
        case 0x0F: return 31 + noise(0.4)
        case 0x10: return 3.1 + d * 62 + noise(0.2)
        case 0x11: return 14 + d * 55 + noise(0.3)
        case 0x14:
            // Лямбда до каталізатора перемикається, але при бідній суміші «сидить» низько
            let s = sin(t * 5.2)
            return lean ? 0.12 + (s > 0.6 ? 0.45 : 0.05) + noise(0.02) : 0.45 + s * 0.38
        case 0x15: return 0.66 + noise(0.02)
        case 0x1F: return t + 240
        case 0x21: return stored.isEmpty ? 0 : 412
        case 0x2F: return 46
        case 0x31: return Double(distanceSinceClear)
        case 0x42: return 14.1 + noise(0.05)
        case 0x44: return 1.0
        case 0x45: return 10 + d * 50
        case 0x46: return 12
        case 0x49: return 15 + d * 50
        case 0x5C: return min(96, 62 + t / 5)
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
        case 0x04, 0x11, 0x2F, 0x45, 0x49: return [u8(v * 255 / 100)]
        case 0x43: return u16(v * 255 / 100)
        case 0x0E: return [u8((v + 64) * 2)]
        case 0x0D, 0x0B, 0x33: return [u8(v)]
        case 0x06, 0x07: return [u8(v * 128 / 100 + 128)]
        case 0x10: return u16(v * 100)
        case 0x14, 0x15: return [u8(v * 200), 0xFF]
        case 0x1F, 0x21, 0x31: return u16(v)
        case 0x42: return u16(v * 1000)
        case 0x44: return u16(v * 65536 / 2)
        default: return nil
        }
    }
}
