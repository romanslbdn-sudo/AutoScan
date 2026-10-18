import Foundation

/// Стан однієї системи самодіагностики (монітора готовності).
public struct ReadinessMonitor: Identifiable, Hashable, Sendable {
    public let name: String
    public let complete: Bool
    public var id: String { name }
}

/// Розшифровка PID 01: лампа Check Engine, кількість помилок, монітори.
public struct MonitorStatus: Hashable, Sendable {
    public let milOn: Bool
    public let dtcCount: Int
    public let isDiesel: Bool
    public let monitors: [ReadinessMonitor]

    public var completeCount: Int { monitors.filter(\.complete).count }

    public init?(bytes d: [UInt8]) {
        guard d.count >= 4 else { return nil }
        let a = d[0], b = d[1], c = d[2], dd = d[3]
        milOn = a & 0x80 != 0
        dtcCount = Int(a & 0x7F)
        isDiesel = b & 0x08 != 0

        var list: [ReadinessMonitor] = []
        // Постійні монітори (байт B): біти 0–2 — підтримка, 4–6 — незавершено.
        let continuous = ["Пропуски запалювання", "Паливна система", "Компоненти"]
        for (i, name) in continuous.enumerated() where b & (1 << i) != 0 {
            list.append(.init(name: name, complete: b & (1 << (i + 4)) == 0))
        }
        let spark = ["Каталізатор", "Підігрів каталізатора", "Система EVAP (пари палива)", "Вторинне повітря",
                     "Кондиціонер", "Лямбда-зонди", "Підігрів лямбда-зондів", "Система EGR"]
        let diesel = ["Каталізатор NMHC", "Система NOx / SCR (AdBlue)", "", "Тиск наддуву",
                      "", "Датчики вихлопних газів", "Сажовий фільтр (DPF)", "EGR / VVT"]
        let names = isDiesel ? diesel : spark
        for i in 0..<8 where c & (1 << i) != 0 && !names[i].isEmpty {
            list.append(.init(name: names[i], complete: dd & (1 << i) == 0))
        }
        monitors = list
    }
}
