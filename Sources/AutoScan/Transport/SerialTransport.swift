#if os(macOS)
import Foundation
import Darwin
import AutoScanCore

/// Адаптер через USB-кабель або класичний Bluetooth (після спарювання в macOS
/// він з'являється як послідовний порт /dev/cu.*).
final class SerialTransport: OBDTransport, @unchecked Sendable {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((String) -> Void)?

    let path: String
    let baudRate: Int
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "autoscan.serial")

    var displayName: String { (path as NSString).lastPathComponent + " · \(baudRate)" }

    init(path: String, baudRate: Int) {
        self.path = path
        self.baudRate = baudRate
    }

    /// Доступні послідовні порти (без службового порту Bluetooth).
    static func availablePorts() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return items
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming-Port") && !$0.contains("debug-console") }
            .sorted()
            .map { "/dev/" + $0 }
    }

    static let baudRates = [9600, 38400, 57600, 115200, 230400, 500000]

    func open() async throws {
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            throw AdapterError.transport("Не вдалося відкрити порт \(path): \(String(cString: strerror(errno))). Можливо, порт зайнятий іншою програмою.")
        }
        // Ексклюзивний доступ до порту
        let TIOCEXCL: UInt = 0x2000_740D  // _IO('t', 13)
        _ = ioctl(handle, TIOCEXCL)

        var options = termios()
        tcgetattr(handle, &options)
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)

        let standard: [Int: speed_t] = [9600: speed_t(B9600), 38400: speed_t(B38400), 57600: speed_t(B57600),
                                        115200: speed_t(B115200), 230400: speed_t(B230400)]
        if let s = standard[baudRate] {
            cfsetispeed(&options, s)
            cfsetospeed(&options, s)
            tcsetattr(handle, TCSANOW, &options)
        } else {
            tcsetattr(handle, TCSANOW, &options)
            // Нестандартна швидкість (напр. 500000) — через IOSSIOSPEED
            var speed = speed_t(baudRate)
            let IOSSIOSPEED: UInt = 0x8008_5402
            if ioctl(handle, IOSSIOSPEED, &speed) == -1 {
                Darwin.close(handle)
                throw AdapterError.transport("Порт не підтримує швидкість \(baudRate).")
            }
        }
        tcflush(handle, TCIOFLUSH)
        fd = handle

        let src = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { Darwin.close(handle) }
        source = src
        src.resume()
        // Невелика пауза: деякі адаптери «прокидаються» після відкриття порту
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 {
            onReceive?(Data(buf[0..<n]))
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            let reason = "Порт закрито (адаптер відключено?)"
            close()
            onDisconnect?(reason)
        }
    }

    func send(_ data: Data) throws {
        guard fd >= 0 else { throw AdapterError.notConnected }
        let written = data.withUnsafeBytes { ptr in Darwin.write(fd, ptr.baseAddress, data.count) }
        if written < 0 {
            throw AdapterError.transport("Помилка запису в порт: \(String(cString: strerror(errno)))")
        }
    }

    func close() {
        guard fd >= 0 else { return }
        fd = -1
        source?.cancel()
        source = nil
    }
}
#endif
