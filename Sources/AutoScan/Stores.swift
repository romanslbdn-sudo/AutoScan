#if os(macOS)
import Foundation
import SwiftUI
import AutoScanCore

/// Поточні значення датчиків.
///
/// Дані від адаптера приходять десятки разів на секунду з фонового потоку.
/// Щоб інтерфейс не перемальовувався на кожне значення (саме це давало підвисання),
/// вони накопичуються в буфері, а на екран потрапляють пачкою 4 рази на секунду.
/// Підписані на цей об'єкт лише екрани з живими даними — бокове меню та інші
/// частини вікна від оновлень датчиків не перемальовуються.
final class LiveStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var values: [UInt8: Double] = [:]
    @Published private(set) var history: [UInt8: [Double]] = [:]

    static let historyLimit = 120

    /// Згладжування: прибирає дрібне «тремтіння» значень. Лямбда-зонди й оберти не згладжуються,
    /// бо їхні швидкі зміни важливі для діагностики (перемикання зонда, пропуски запалювання).
    var smoothing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _smoothing }
        set { lock.lock(); _smoothing = newValue; lock.unlock(); UserDefaults.standard.set(newValue, forKey: "live.smoothing") }
    }
    private var _smoothing = UserDefaults.standard.object(forKey: "live.smoothing") as? Bool ?? true
    private static let rawPIDs: Set<UInt8> = [0x0C, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x0D, 0xA4]

    private let lock = NSLock()
    private var bufValues: [UInt8: Double] = [:]
    private var bufHistory: [UInt8: [Double]] = [:]
    private var dirty = false

    /// Записати значення (можна з будь-якого потоку).
    func record(_ pid: UInt8, _ raw: Double) {
        lock.lock()
        var value = raw
        if _smoothing, !Self.rawPIDs.contains(pid), let prev = bufValues[pid] {
            value = prev + (raw - prev) * 0.45
        }
        bufValues[pid] = value
        var h = bufHistory[pid] ?? []
        h.append(value)
        if h.count > Self.historyLimit { h.removeFirst(h.count - Self.historyLimit) }
        bufHistory[pid] = h
        dirty = true
        lock.unlock()
    }

    /// Останнє записане значення (з будь-якого потоку).
    func latest(_ pid: UInt8) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return bufValues[pid]
    }

    /// Перенести накопичене на екран (викликається на головному потоці).
    @MainActor
    func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let v = bufValues, h = bufHistory
        dirty = false
        lock.unlock()
        values = v
        history = h
    }

    @MainActor
    func reset(keepValues: Bool = true) {
        lock.lock()
        bufHistory = [:]
        if !keepValues { bufValues = [:] }
        dirty = false
        lock.unlock()
        history = [:]
        if !keepValues { values = [:] }
    }
}

/// Журнал обміну з адаптером — так само пачками, щоб не гальмувати інтерфейс.
final class LogStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var lines: [AdapterLogLine] = []

    private let lock = NSLock()
    private var buffer: [AdapterLogLine] = []
    private let limit = 600

    func record(_ line: AdapterLogLine) {
        lock.lock()
        buffer.append(line)
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        lock.unlock()
    }

    @MainActor
    func flush() {
        lock.lock()
        guard !buffer.isEmpty else { lock.unlock(); return }
        let new = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        var all = lines + new
        if all.count > limit { all.removeFirst(all.count - limit) }
        lines = all
    }

    @MainActor
    func clear() {
        lock.lock(); buffer.removeAll(); lock.unlock()
        lines = []
    }
}
#endif
