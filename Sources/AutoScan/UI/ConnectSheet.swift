#if os(macOS)
import SwiftUI
import AppKit
import AutoScanCore

/// Вікно підключення: покроково і простими словами.
struct ConnectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ble = BLEManager.shared

    @AppStorage("conn.kind") private var kindRaw = ConnectionKind.demo.rawValue
    @AppStorage("conn.serial") private var serialPath = ""
    @AppStorage("conn.baud") private var baud = 0          // 0 — підібрати автоматично
    @AppStorage("conn.host") private var host = "192.168.0.10"
    @AppStorage("conn.port") private var port = 35000
    @AppStorage("conn.demo") private var demoID = DemoScenario.default.id

    @State private var ports: [String] = []
    /// Вибраний Bluetooth-пристрій: або знайдений поруч (BLE), або спарений у налаштуваннях Mac.
    @State private var bleSelection: UUID?
    @State private var classicSelection: String?
    @State private var showWhichAdapter = false
    @State private var showAdvanced = false

    private var kind: ConnectionKind { ConnectionKind(rawValue: kindRaw) ?? .demo }
    private var usbPorts: [String] { ports.filter { SerialTransport.describe($0).kind == .usb } }
    private var classicPorts: [String] { ports.filter { SerialTransport.describe($0).kind == .bluetooth } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 16)

            kindPicker
                .padding(.horizontal, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch kind {
                    case .demo: demoPane
                    case .usb: usbPane
                    case .wifi: wifiPane
                    case .bluetooth: blePane
                    }
                }
                .padding(24)
            }
            .frame(height: 380)

            Divider().overlay(Theme.stroke)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 640)
        .background(Theme.background)
        .onAppear {
            refreshPorts()
            if kind == .bluetooth { ble.startScan() }
        }
        .onChange(of: kindRaw) { _ in
            refreshPorts()
            if kind == .bluetooth { ble.startScan() } else { ble.stopScan() }
        }
        .onDisappear { ble.stopScan() }
    }

    // MARK: Шапка і вибір типу

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Підключення до авто").font(Theme.title).foregroundStyle(Theme.textPrimary)
                Text("Як ваш адаптер з'єднується з Маком?")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                .buttonStyle(SubtleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                kindCard(.usb, "Кабель USB", "дротом до Мака")
                kindCard(.bluetooth, "Bluetooth", "без дроту")
                kindCard(.wifi, "Wi‑Fi", "своя Wi‑Fi мережа")
                kindCard(.demo, "Демо", "без машини")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showWhichAdapter.toggle() }
            } label: {
                Label(showWhichAdapter ? "Сховати підказку" : "Не знаєте, який у вас адаптер?", systemImage: "questionmark.circle")
                    .font(Theme.caption)
            }
            .buttonStyle(.link)
            if showWhichAdapter {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        hintRow("cable.connector", "Від адаптера йде дріт зі штекером USB — це **Кабель USB**.")
                        hintRow("dot.radiowaves.left.and.right", "Маленький адаптер без дроту, на ньому або на коробці написано **Bluetooth**, «BLE» або «4.0» — це **Bluetooth**.")
                        hintRow("wifi", "На адаптері чи коробці написано **WiFi** — це **Wi‑Fi**.")
                        hintRow("car", "Найчастіше адаптер виглядає як невелика коробочка, яка вставляється в роз'єм під кермом (біля педалей).")
                        Divider().overlay(Theme.stroke)
                        hintRow("checkmark.seal", "**Підходять:** будь-які сканери на ELM327 — Vgate (iCar), Veepeak, Konnwei, OBDLink, V-LINK, а також дешеві китайські клони «ELM327 v1.5 / v2.1».")
                        hintRow("xmark.seal", "**Не підходять:** фірмові сканери зі своєю програмою (Launch, Autel, Thinkcar), кабелі VAG-COM/VCDS і J2534 — вони працюють лише з програмами виробника.")
                    }
                }
            }
        }
    }

    private func kindCard(_ k: ConnectionKind, _ title: String, _ subtitle: String) -> some View {
        let on = kind == k
        return Button { kindRaw = k.rawValue } label: {
            VStack(spacing: 5) {
                Image(systemName: k.icon).font(.system(size: 20))
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.cardRaised : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(on ? Theme.accent : Theme.stroke, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hintRow(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 18)
            Text(text).font(Theme.body).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Кроки

    private func steps(_ items: [LocalizedStringKey]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Що зробити").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.accent.opacity(0.18)))
                        .foregroundStyle(Theme.accent)
                    Text(text).font(Theme.body).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func deviceRow(icon: String, title: String, detail: String, badge: String? = nil,
                           selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if let badge { Pill(text: badge, color: Theme.accent) }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.cardRaised : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? Theme.accent : Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String, trailing: AnyView? = nil) -> some View {
        HStack {
            Text(text).font(Theme.headline).foregroundStyle(Theme.textPrimary)
            Spacer()
            trailing
        }
        .padding(.top, 4)
    }

    private func note(_ icon: String, _ text: LocalizedStringKey, color: Color = Theme.textTertiary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Демо

    private var demoPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Виберіть віртуальне авто — у кожного свої поломки. Так можна подивитися всі екрани без машини і адаптера.")
                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(DemoScenario.all) { sc in
                deviceRow(icon: sc.isDiesel ? "fuelpump.fill" : "car.fill",
                          title: "\(sc.car) · \(sc.year)",
                          detail: "\(sc.engine) — \(sc.summary)",
                          badge: sc.faultCount == 0 ? "справне" : "помилок: \(sc.faultCount)",
                          selected: demoID == sc.id) { demoID = sc.id }
            }
        }
    }

    // MARK: USB

    private var usbPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            steps([
                "Вставте адаптер у роз'єм OBD2 машини (зазвичай під кермом, біля педалей).",
                "З'єднайте адаптер з Маком кабелем USB.",
                "Увімкніть запалювання (двигун можна не заводити).",
                "Виберіть адаптер у списку нижче й натисніть **«Підключитися»**.",
            ])
            sectionTitle("Адаптери, які бачить Мак", trailing: AnyView(
                Button { refreshPorts() } label: { Label("Оновити", systemImage: "arrow.clockwise") }
                    .buttonStyle(SubtleButtonStyle())))
            if usbPorts.isEmpty {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Мак поки не бачить USB-адаптер", systemImage: "cable.connector.slash")
                            .font(Theme.headline).foregroundStyle(Theme.warning)
                        Text("Перевірте, що кабель вставлений, і натисніть «Оновити». Якщо не допомагає — дешевим адаптерам з чипом CH340 потрібен драйвер виробника (шукайте «CH340 driver macOS»).")
                            .font(Theme.body).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ForEach(usbPorts, id: \.self) { p in
                    let d = SerialTransport.describe(p)
                    deviceRow(icon: "cable.connector", title: d.title, detail: d.detail,
                              selected: serialPath == p) { serialPath = p }
                }
            }
            advanced {
                HStack {
                    Text("Швидкість порту").font(Theme.body).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("", selection: $baud) {
                        Text("Автоматично").tag(0)
                        ForEach(SerialTransport.baudRates, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                note("info.circle", "Залиште «Автоматично» — програма сама підбере швидкість.")
            }
        }
    }

    // MARK: Bluetooth

    private var blePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            steps([
                "Вставте адаптер у роз'єм OBD2 і увімкніть запалювання — на адаптері має засвітитися лампочка.",
                "Зачекайте кілька секунд: адаптер з'явиться у списку нижче (зазвичай називається **OBDII**, **Vgate**, **Veepeak**, **V-LINK** або **OBDLink**).",
                "Виберіть його й натисніть **«Підключитися»**.",
            ])

            if !ble.stateText.isEmpty {
                note("exclamationmark.triangle.fill", LocalizedStringKey(ble.stateText), color: Theme.warning)
            }

            sectionTitle("Знайдені поруч", trailing: AnyView(
                HStack(spacing: 8) {
                    if ble.isScanning { ProgressView().controlSize(.small) }
                    Button(ble.isScanning ? "Зупинити" : "Шукати ще") {
                        ble.isScanning ? ble.stopScan() : ble.startScan()
                    }
                    .buttonStyle(SubtleButtonStyle())
                }))

            let likely = ble.devices.filter(\.looksLikeOBD)
            let others = ble.devices.filter { !$0.looksLikeOBD }
            if likely.isEmpty && classicPorts.isEmpty {
                Text(ble.isScanning ? "Шукаю адаптер…" : "Нічого не знайдено. Натисніть «Шукати ще».")
                    .font(Theme.body).foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 6)
            }
            ForEach(likely) { d in
                deviceRow(icon: "car.fill", title: d.name, detail: "Bluetooth-адаптер · сигнал \(signal(d.rssi))",
                          badge: "схоже на OBD", selected: bleSelection == d.id) {
                    bleSelection = d.id; classicSelection = nil
                }
            }
            ForEach(classicPorts, id: \.self) { p in
                let d = SerialTransport.describe(p)
                deviceRow(icon: "link", title: d.title, detail: "з'єднаний з Маком через налаштування Bluetooth",
                          selected: classicSelection == p) {
                    classicSelection = p; bleSelection = nil
                }
            }
            if !others.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 6) {
                        ForEach(others) { d in
                            deviceRow(icon: "dot.radiowaves.right", title: d.name, detail: "сигнал \(signal(d.rssi))",
                                      selected: bleSelection == d.id) {
                                bleSelection = d.id; classicSelection = nil
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Інші пристрої поруч (\(others.count)) — навушники, телефони тощо")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }

            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Адаптера немає у списку?", systemImage: "questionmark.circle")
                        .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                    Text("Старіші адаптери працюють через «класичний» Bluetooth. Їх треба один раз з'єднати з Маком:")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1.  → Системні параметри → **Bluetooth**")
                        Text("2. Знайдіть адаптер (OBDII тощо) → **Під'єднати**")
                        Text("3. Якщо спитає PIN — введіть **1234** (або 0000)")
                        Text("4. Поверніться сюди — адаптер з'явиться в списку вище")
                    }
                    .font(Theme.body).foregroundStyle(Theme.textPrimary)
                    Button("Відкрити налаштування Bluetooth") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .padding(.top, 2)
                }
            }
        }
    }

    private func signal(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...: return "сильний"
        case (-75)...: return "добрий"
        default: return "слабкий"
        }
    }

    // MARK: Wi‑Fi

    private var wifiPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            steps([
                "Вставте адаптер у роз'єм OBD2 і увімкніть запалювання.",
                "На Маку натисніть значок **Wi‑Fi** у верхньому правому куті екрана й підключіться до мережі адаптера (назва на кшталт **WiFi_OBDII**, **OBDII** або **V-LINK**).",
                "Поверніться сюди й натисніть **«Підключитися»**.",
            ])
            note("info.circle", "Поки Мак підключений до адаптера, інтернет не працюватиме — це нормально. Після діагностики поверніться до своєї звичайної Wi‑Fi мережі.")
            note("hand.raised", "При першому підключенні macOS може спитати дозвіл на доступ до локальної мережі — натисніть «Дозволити».")
            advanced {
                HStack {
                    Text("Адреса адаптера").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
                    TextField("192.168.0.10", text: $host).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Порт").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
                    TextField("35000", value: $port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 110)
                    Spacer()
                    Button("Скинути") { host = "192.168.0.10"; port = 35000 }.buttonStyle(.link)
                }
                note("info.circle", "Міняйте, лише якщо в інструкції адаптера вказано іншу адресу (буває 192.168.1.10).")
            }
        }
    }

    // MARK: Додатково

    private func advanced<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let inner = content()
        return DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) { inner }
                .padding(.top, 8)
        } label: {
            Text("Додаткові налаштування (зазвичай не потрібні)")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Низ вікна

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine
            HStack {
                if model.connection.isConnected {
                    Button("Відключитися") { model.disconnect() }
                        .buttonStyle(SubtleButtonStyle(color: Theme.danger))
                }
                Spacer()
                if !canConnect, let why = whyCannotConnect {
                    Text(why).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Button(model.connection.isBusy ? "Підключення…" : "Підключитися") { connect() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canConnect || model.connection.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var canConnect: Bool {
        switch kind {
        case .demo: return true
        case .usb: return usbPorts.contains(serialPath)
        case .wifi: return !host.isEmpty && port > 0
        case .bluetooth: return bleSelection != nil || classicSelection != nil
        }
    }

    private var whyCannotConnect: String? {
        switch kind {
        case .usb: return usbPorts.isEmpty ? nil : "Виберіть адаптер у списку"
        case .bluetooth: return "Виберіть адаптер у списку"
        default: return nil
        }
    }

    private func refreshPorts() {
        ports = SerialTransport.availablePorts()
        if !usbPorts.contains(serialPath) { serialPath = usbPorts.first ?? "" }
        if let c = classicSelection, !classicPorts.contains(c) { classicSelection = nil }
    }

    private func connect() {
        switch kind {
        case .demo:
            model.connect(kind: .demo, demo: DemoScenario.with(id: demoID))
        case .usb:
            model.connect(kind: .usb, serialPath: serialPath, baud: baud)
        case .wifi:
            model.connect(kind: .wifi, host: host, port: UInt16(clamping: port))
        case .bluetooth:
            if let p = classicSelection {
                // Класичний Bluetooth працює як послідовний порт
                model.connect(kind: .usb, serialPath: p, baud: baud)
            } else {
                let device = ble.devices.first { $0.id == bleSelection }
                model.connect(kind: .bluetooth, bleDevice: device)
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
                    Button("Подивитися журнал адаптера") {
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
