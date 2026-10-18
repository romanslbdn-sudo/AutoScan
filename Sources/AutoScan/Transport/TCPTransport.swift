#if os(macOS)
import Foundation
import Network
import AutoScanCore

/// Wi‑Fi адаптер ELM327. Спершу Mac треба підключити до Wi‑Fi мережі адаптера
/// (зазвичай «WiFi_OBDII», «V-LINK» тощо); типова адреса — 192.168.0.10:35000.
final class TCPTransport: OBDTransport, @unchecked Sendable {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((String) -> Void)?

    let host: String
    let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "autoscan.tcp")
    private var closedByUser = false

    var displayName: String { "\(host):\(port)" }

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func open() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw AdapterError.transport("Неправильний порт \(port)")
        }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let lock = NSLock()
            func finish(_ r: Result<Void, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(with: r)
            }
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .waiting(let err):
                    finish(.failure(AdapterError.transport("Немає зв'язку з \(self?.host ?? ""): \(err.localizedDescription). Перевірте, що Mac підключений до Wi‑Fi мережі адаптера.")))
                    conn.cancel()
                case .failed(let err):
                    finish(.failure(AdapterError.transport("З'єднання не вдалося: \(err.localizedDescription)")))
                    self?.handleDrop("Wi‑Fi з'єднання з адаптером обірвалося")
                case .cancelled:
                    finish(.failure(AdapterError.transport("З'єднання скасовано")))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) {
                finish(.failure(AdapterError.transport("Адаптер не відповідає за адресою \(self.host):\(self.port). Перевірте Wi‑Fi підключення до адаптера.")))
            }
        }
        receiveLoop()
    }

    private func handleDrop(_ reason: String) {
        guard !closedByUser else { return }
        closedByUser = true
        onDisconnect?(reason)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(data) }
            if complete || error != nil {
                self.handleDrop("Адаптер закрив з'єднання")
                return
            }
            self.receiveLoop()
        }
    }

    func send(_ data: Data) throws {
        guard let connection else { throw AdapterError.notConnected }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        closedByUser = true
        connection?.cancel()
        connection = nil
    }
}
#endif
