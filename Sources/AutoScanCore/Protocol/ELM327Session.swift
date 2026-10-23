import Foundation

/// Канал зв'язку з адаптером (USB, Wi‑Fi, Bluetooth або демо).
public protocol OBDTransport: AnyObject {
    /// Викликається, коли від адаптера прийшли байти (з будь-якого потоку).
    var onReceive: ((Data) -> Void)? { get set }
    /// Викликається, якщо з'єднання обірвалося.
    var onDisconnect: ((String) -> Void)? { get set }
    var displayName: String { get }
    func open() async throws
    func send(_ data: Data) throws
    func close()
}

/// Простий асинхронний замок: команди до адаптера йдуть строго по черзі.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

/// Запис у журналі обміну з адаптером (для діагностики проблем зі зв'язком).
public struct AdapterLogLine: Identifiable, Sendable {
    public enum Direction: Sendable { case sent, received, info, error }
    public let id = UUID()
    public let time: Date
    public let direction: Direction
    public let text: String
}

/// Сеанс роботи з адаптером ELM327: надсилає команди й чекає запрошення «>».
public final class ELM327Session: @unchecked Sendable {
    public let transport: OBDTransport
    public var onLog: ((AdapterLogLine) -> Void)?

    private let state = NSLock()
    private var buffer = ""
    private var waiter: CheckedContinuation<String, Error>?
    private var waiterToken = 0
    private let commandLock = AsyncLock()

    public init(transport: OBDTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] data in self?.receive(data) }
    }

    private func log(_ d: AdapterLogLine.Direction, _ t: String) {
        onLog?(AdapterLogLine(time: Date(), direction: d, text: t))
    }

    private func receive(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
        state.lock()
        buffer += chunk
        guard let promptIndex = buffer.firstIndex(of: ">"), let w = waiter else {
            state.unlock()
            return
        }
        let response = String(buffer[..<promptIndex])
        buffer = String(buffer[buffer.index(after: promptIndex)...])
        waiter = nil
        state.unlock()
        w.resume(returning: response)
    }

    private func failWaiter(token: Int, error: Error) {
        state.lock()
        guard waiterToken == token, let w = waiter else { state.unlock(); return }
        waiter = nil
        state.unlock()
        w.resume(throwing: error)
    }

    /// Надсилає команду і повертає відповідь без запрошення «>».
    public func command(_ cmd: String, timeout: TimeInterval = 4) async throws -> String {
        await commandLock.lock()
        defer { Task { await commandLock.unlock() } }

        log(.sent, cmd)
        let response: String
        do {
            response = try await exchange(cmd, timeout: timeout)
        } catch AdapterError.timeout {
            // Запізніла відповідь могла б дістатися наступній команді (напр. «помилок немає»
            // замість справжніх кодів). Тому зупиняємо адаптер і викидаємо все, що він ще надішле.
            await resync()
            throw AdapterError.timeout
        }
        let cleaned = Self.stripEcho(response, command: cmd)
        log(.received, cleaned.replacingOccurrences(of: "\r", with: " ⏎ ").trimmingCharacters(in: .whitespaces))
        return cleaned
    }

    /// Час тиші, після якого вважаємо, що адаптер усе договорив.
    static let resyncQuietTime: TimeInterval = 0.3
    static let resyncMaxTime: TimeInterval = 2

    /// Будь-який символ перериває запит, який адаптер ще виконує. «ATI» нешкідлива:
    /// на відміну від порожнього рядка, вона не повторює попередню команду (напр. стирання помилок).
    private func resync() async {
        log(.info, "Адаптер не відповів вчасно — синхронізую зв'язок")
        try? transport.send(Data("ATI\r".utf8))
        let start = Date()
        var lastSize = -1
        var quietSince = Date()
        while Date().timeIntervalSince(start) < Self.resyncMaxTime {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let (size, hasPrompt) = bufferSnapshot()
            if size != lastSize { lastSize = size; quietSince = Date(); continue }
            if hasPrompt && Date().timeIntervalSince(quietSince) >= Self.resyncQuietTime { break }
        }
        clearBuffer()
    }

    private func bufferSnapshot() -> (size: Int, hasPrompt: Bool) {
        state.lock(); defer { state.unlock() }
        return (buffer.count, buffer.contains(">"))
    }

    private func clearBuffer() {
        state.lock(); buffer = ""; state.unlock()
    }

    private func exchange(_ cmd: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            state.lock()
            buffer = ""
            waiterToken += 1
            let token = waiterToken
            waiter = cont
            state.unlock()
            do {
                try transport.send(Data((cmd + "\r").utf8))
            } catch {
                failWaiter(token: token, error: AdapterError.transport(error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.failWaiter(token: token, error: AdapterError.timeout)
            }
        }
    }

    static func stripEcho(_ response: String, command: String) -> String {
        var r = response
        let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix(command.uppercased()) {
            r = String(trimmed.dropFirst(command.count))
        }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func info(_ text: String) { log(.info, text) }
    public func error(_ text: String) { log(.error, text) }
}
