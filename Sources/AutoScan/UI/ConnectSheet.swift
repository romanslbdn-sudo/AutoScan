#if os(macOS)
import SwiftUI
import AutoScanCore

struct ConnectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ble = BLEManager.shared

    @AppStorage("conn.kind") private var kindRaw = ConnectionKind.demo.rawValue
    @AppStorage("conn.serial") private var serialPath = ""
    @AppStorage("conn.baud") private var baud = 38400
    @AppStorage("conn.host") private var host = "192.168.0.10"
    @AppStorage("conn.port") private var port = 35000
    @State private var ports: [String] = []
    @State private var bleSelection: UUID?

    private var kind: ConnectionKind { ConnectionKind(rawValue: kindRaw) ?? .demo }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Підключення до авто").font(Theme.title).foregroundStyle(Theme.textPrimary)
                    Text("Вставте адаптер ELM327 у роз'єм OBD2 і увімкніть запалювання.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(SubtleButtonStyle())
                .keyboardShortcut(.cancelAction)
            }

            // Вибір типу адаптера
            HStack(spacing: 8) {
                ForEach(ConnectionKind.allCases) { k in
                    Button { kindRaw = k.rawValue } label: {
                        VStack(spacing: 6) {
                            Image(systemName: k.icon).font(.system(size: 18))
                            Text(k.title).font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(kind == k ? Theme.textPrimary : Theme.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(kind == k ? Theme.cardRaised : Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(kind == k ? Theme.accent : Theme.stroke, lineWidth: kind == k ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Group {
                switch kind {
                case .demo: demoPane
                case .usb: usbPane
                case .wifi: wifiPane
                case .bluetooth: blePane
                }
            }
            .frame(minHeight: 190, alignment: .top)

            statusLine

            HStack {
                if model.connection.isConnected {
                    Button("Відключитися") { model.disconnect() }
                        .buttonStyle(SubtleButtonStyle(color: Theme.danger))
                }
                Spacer()
                Button(model.connection.isBusy ? "Підключення…" : "Підключитися") { connect() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canConnect || model.connection.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Theme.background)
        .onAppear {
            ports = SerialTransport.availablePorts()
            if serialPath.isEmpty || !ports.contains(serialPath) { serialPath = ports.first ?? "" }
            if kind == .bluetooth { ble.startScan() }
        }
        .onChange(of: kindRaw) { _ in
            if kind == .bluetooth { ble.startScan() } else { ble.stopScan() }
        }
        .onDisappear { ble.stopScan() }
    }

    private var canConnect: Bool {
        switch kind {
        case .demo: return true
        case .usb: return !serialPath.isEmpty
        case .wifi: return !host.isEmpty && port > 0
        case .bluetooth: return bleSelection != nil
        }
    }

    private func connect() {
        switch kind {
        case .demo: model.connect(kind: .demo)
        case .usb: model.connect(kind: .usb, serialPath: serialPath, baud: baud)
        case .wifi: model.connect(kind: .wifi, host: host, port: UInt16(clamping: port))
        case .bluetooth:
            let device = ble.devices.first { $0.id == bleSelection }
            model.connect(kind: .bluetooth, bleDevice: device)
        }
    }

    // MARK: Панелі

    private var demoPane: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Віртуальне авто без адаптера", systemImage: "car.side")
                    .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                Text("Програма імітує бензиновий турбодвигун з трьома несправностями: бідна суміш (P0171), недостатній наддув (P0299) і пропуски запалювання в 1-му циліндрі (P0301). Так можна подивитися всі екрани, зокрема «Норма vs зараз», без машини.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var usbPane: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Порт").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                    Picker("", selection: $serialPath) {
                        if ports.isEmpty { Text("Портів не знайдено").tag("") }
                        ForEach(ports, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                    }
                    .labelsHidden()
                    Button { ports = SerialTransport.availablePorts(); if !ports.contains(serialPath) { serialPath = ports.first ?? "" } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .help("Оновити список портів")
                }
                HStack {
                    Text("Швидкість").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                    Picker("", selection: $baud) {
                        ForEach(SerialTransport.baudRates, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Spacer()
                }
                Text("Для більшості USB-адаптерів ELM327 підходить 38400. Якщо не підключається — спробуйте 115200 або 9600. Класичний Bluetooth-адаптер після спарювання в налаштуваннях Mac теж з'являється тут як порт (напр. «cu.OBDII»). Деяким USB-адаптерам (чип CH340) потрібен драйвер виробника.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var wifiPane: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Адреса").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                    TextField("192.168.0.10", text: $host).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Порт").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                    TextField("35000", value: $port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 120)
                    Spacer()
                }
                Text("Спершу підключіть Mac до Wi‑Fi мережі адаптера (назва на кшталт «WiFi_OBDII» або «V-LINK»). Найчастіше адреса 192.168.0.10, порт 35000; у деяких адаптерів — 192.168.1.10.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var blePane: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(ble.isScanning ? "Пошук пристроїв…" : "Пристрої поруч")
                        .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                    if ble.isScanning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(ble.isScanning ? "Зупинити" : "Шукати") {
                        ble.isScanning ? ble.stopScan() : ble.startScan()
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                if !ble.stateText.isEmpty {
                    Text(ble.stateText).font(Theme.caption).foregroundStyle(Theme.warning)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(ble.devices) { d in
                            Button { bleSelection = d.id } label: {
                                HStack {
                                    Image(systemName: d.looksLikeOBD ? "car.fill" : "dot.radiowaves.right")
                                        .foregroundStyle(d.looksLikeOBD ? Theme.accent : Theme.textTertiary)
                                        .frame(width: 20)
                                    Text(d.name).font(Theme.body).foregroundStyle(Theme.textPrimary)
                                    if d.looksLikeOBD { Pill(text: "схоже на OBD", color: Theme.accent) }
                                    Spacer()
                                    Text("\(d.rssi) дБм").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 7).fill(bleSelection == d.id ? Theme.cardRaised : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(bleSelection == d.id ? Theme.accent : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if ble.devices.isEmpty && ble.isScanning {
                            Text("Переконайтеся, що адаптер вставлений і запалювання увімкнене.")
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(.top, 20)
                        }
                    }
                }
                .frame(height: 140)
                Text("Тут — адаптери Bluetooth LE (4.0). Класичні Bluetooth-адаптери спершу спарюються в налаштуваннях Mac і вибираються у вкладці «USB / кабель».")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch model.connection {
        case .connecting(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
        case .failed(let reason):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason).font(Theme.body).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Відкрити журнал адаптера") {
                        model.screen = .log
                        dismiss()
                    }
                    .buttonStyle(.link)
                    .font(Theme.caption)
                }
            }
        case .connected:
            Label("Підключено: \(model.adapterName) · \(model.connInfo.protocolName)", systemImage: "checkmark.circle.fill")
                .font(Theme.body).foregroundStyle(Theme.ok)
        case .disconnected:
            EmptyView()
        }
    }
}
#endif
