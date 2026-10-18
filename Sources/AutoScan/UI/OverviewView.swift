#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AutoScanCore

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.connection.isConnected {
            NotConnectedView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Огляд", subtitle: headerSubtitle) {
                        HStack(spacing: 8) {
                            Button {
                                Task { await model.readVehicle(); await model.readDTCs() }
                            } label: { Label("Оновити", systemImage: "arrow.clockwise") }
                            .buttonStyle(SubtleButtonStyle())
                            ReportButton()
                            Button {
                                model.finishSession(startNew: true)
                            } label: { Label("Нова діагностика", systemImage: "plus.circle") }
                            .buttonStyle(AccentButtonStyle())
                            .help("Завершити поточну діагностику й підключитися до іншого авто")
                        }
                    }

                    if let item = model.suggestedPack {
                        SuggestedPackBanner(item: item)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        VehicleCard()
                        StatusCard()
                    }

                    HStack(alignment: .top, spacing: 16) {
                        QuickGauges()
                        ReadinessCard()
                    }

                    KeyReadings()
                }
                .padding(28)
            }
        }
    }

    private var headerSubtitle: String {
        if let v = model.vin, let m = v.manufacturer {
            return [m, v.modelYear.map { "\($0) р." }].compactMap { $0 }.joined(separator: " · ")
        }
        return "Загальний стан авто"
    }
}

/// Підказка: для марки цього авто є пакет заводських кодів.
private struct SuggestedPackBanner: View {
    @EnvironmentObject var model: AppModel
    let item: PackCatalog.Item

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Для \(item.brand) є пакет заводських кодів").font(Theme.headline).foregroundStyle(Theme.textPrimary)
                Text("\(item.codes) додаткових кодів саме цієї марки — точніші описи помилок.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if model.installingPackID == item.id {
                ProgressView().controlSize(.small)
            } else {
                Button(model.status(of: item) == .updateAvailable ? "Оновити" : "Завантажити") {
                    Task { await model.install(item) }
                }
                .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent.opacity(0.35)))
    }
}

struct NotConnectedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.08)).frame(width: 150, height: 150)
                Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 1).frame(width: 150, height: 150)
                Image(systemName: "car.side.rear.open")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 8) {
                Text("Підключіть адаптер").font(Theme.largeTitle).foregroundStyle(Theme.textPrimary)
                Text("Вставте адаптер ELM327 у роз'єм OBD2 (зазвичай під кермом), увімкніть запалювання і натисніть «Підключитися». Без машини можна спробувати демо-режим.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            HStack(spacing: 10) {
                Button("Підключитися") { model.showConnectSheet = true }
                    .buttonStyle(AccentButtonStyle())
                Button("Спробувати демо") {
                    UserDefaults.standard.set(ConnectionKind.demo.rawValue, forKey: "conn.kind")
                    model.showConnectSheet = true
                }
                    .buttonStyle(SubtleButtonStyle())
            }
            if case .connecting(let text) = model.connection {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).foregroundStyle(Theme.textSecondary) }
            }
            if case .failed(let reason) = model.connection {
                Text(reason).font(Theme.body).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Text("OBD2 є на бензинових авто з 2001 року і дизельних з 2004 року (у Європі), в США — з 1996 року.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct VehicleCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveStore

    var body: some View {
        let d = model.details
        let title = [d?.make ?? model.vin?.brandKey, d?.model].compactMap { $0 }.joined(separator: " ")
        let year = d?.year ?? model.vin?.modelYear
        let displacement = model.displacementText(live)
        let turbo = model.turboText(live)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Автомобіль", systemImage: "car.fill").font(Theme.headline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if model.isLookingUpVIN {
                        ProgressView().controlSize(.small)
                        Text("шукаю дані за VIN…").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }

                // Назва і головне про двигун — великими літерами
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.isEmpty ? (model.vin == nil ? "Марку не визначено" : "Модель невідома") : title)
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        if let y = year { Pill(text: "\(y) р.", color: Theme.textSecondary) }
                        if let dsp = displacement { Pill(text: dsp.0, color: Theme.accent, icon: "engine.combustion") }
                        if let f = model.fuelText { Pill(text: f, color: model.fuelText == "дизель" ? Theme.warning : Theme.info, icon: "fuelpump") }
                        if let t = turbo, t.0.hasPrefix("так") || t.0.hasPrefix("ймовірно") { Pill(text: "турбо", color: Theme.danger, icon: "tornado") }
                    }
                }

                // Двигун
                section("Двигун") {
                    if let dsp = displacement { infoRow("Об'єм", dsp.0, note: dsp.1) }
                    if let f = model.fuelText { infoRow("Паливо", f) }
                    if let t = turbo { infoRow("Турбіна", t.0, note: t.1) }
                    if let c = d?.cylinders { infoRow("Циліндрів", "\(c)") }
                    if let p = d?.powerText { infoRow("Потужність", p) }
                    if let code = d?.engineCode { infoRow("Код / модель двигуна", code) }
                    if displacement == nil && d?.cylinders == nil {
                        Text("Об'єм з'явиться, щойно двигун попрацює на холостому (програма оцінить його за витратою повітря), або коли знайдуться дані за VIN.")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Кузов і трансмісія
                if d?.body != nil || d?.drive != nil || d?.transmission != nil || d?.trim != nil {
                    section("Кузов і трансмісія") {
                        if let b = d?.body { infoRow("Кузов", b) }
                        if let t = d?.trim { infoRow("Комплектація", t) }
                        if let tr = d?.transmission { infoRow("Коробка", tr) }
                        if let dr = d?.drive { infoRow("Привід", dr) }
                    }
                }

                // Паспорт
                section("Паспорт авто") {
                    if let v = model.vin {
                        infoRow("VIN", v.vin, mono: true)
                        if let c = v.country { infoRow("Країна виробництва", c) }
                    } else {
                        Text("Авто не передало VIN (часто до 2005 р.). Марку можна вказати вручну в «Бази авто».")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let p = d?.plant { infoRow("Завод", p) }
                    if let std = model.obdStandard { infoRow("Стандарт діагностики", std) }
                }

                // Зв'язок
                section("Зв'язок") {
                    infoRow("Сканер", model.connInfo.adapterKind.isEmpty ? model.adapterName : model.connInfo.adapterKind)
                    if let note = model.connInfo.adapterNote {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(Theme.caption).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    infoRow("Протокол", model.connInfo.protocolName)
                    infoRow("Параметрів передає авто", "\(PIDTable.all.filter { model.isSupported($0.pid) }.count)")
                }

                if let src = d?.source {
                    Text("Джерело даних про модель і двигун: \(src). Для європейських авто онлайн-база VIN буває неповною.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary).kerning(0.5)
            content()
        }
    }

    private func infoRow(_ label: String, _ value: String, note: String? = nil, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            InfoRow(label: label, value: value, mono: mono)
            if let note, !note.isEmpty {
                Text(note).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct StatusCard: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        let mil = model.monitor?.milOn ?? false
        let stored = model.dtcs.filter { $0.kind == .stored }.count
        let pending = model.dtcs.filter { $0.kind == .pending }.count
        let permanent = model.dtcs.filter { $0.kind == .permanent }.count
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Label("Стан", systemImage: "stethoscope").font(Theme.headline).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill((mil ? Theme.warning : Theme.ok).opacity(0.14)).frame(width: 64, height: 64)
                        Image(systemName: "engine.combustion.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(mil ? Theme.warning : Theme.ok)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mil ? "Лампа Check Engine горить" : "Лампа Check Engine не горить")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(summary(stored: stored, pending: pending))
                            .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(spacing: 10) {
                    countBox("Активні", stored, Theme.danger)
                    countBox("Очікувані", pending, Theme.warning)
                    countBox("Постійні", permanent, Theme.info)
                }
                HStack {
                    if model.isReadingDTCs {
                        ProgressView().controlSize(.small)
                        Text("Читаю помилки…").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    } else if let d = model.lastDTCRead {
                        Text("Прочитано о \(d.formatted(date: .omitted, time: .shortened))").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if !model.dtcs.isEmpty {
                        Button("Переглянути помилки →") { model.screen = .faults }
                            .buttonStyle(.link)
                        Button {
                            confirmClear = true
                        } label: {
                            Label(model.isClearing ? "Стираю…" : "Стерти помилки", systemImage: "trash")
                        }
                        .buttonStyle(SubtleButtonStyle(color: Theme.danger))
                        .disabled(model.isClearing)
                    }
                }
            }
        }
        .confirmationDialog("Стерти всі помилки?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Стерти", role: .destructive) { Task { await model.clearDTCs() } }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Запалювання має бути увімкнене, двигун — заглушений. Скинуться й монітори готовності. Якщо причину не усунуто — помилка повернеться.")
        }
    }

    private func summary(stored: Int, pending: Int) -> String {
        if stored == 0 && pending == 0 { return "Помилок у блоці двигуна не знайдено" }
        return "Знайдено помилок: \(model.uniqueCodes.count)"
    }

    private func countBox(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(Theme.number(24)).foregroundStyle(n > 0 ? color : Theme.textTertiary)
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardRaised))
    }
}

private struct QuickGauges: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Зараз", systemImage: "speedometer").font(Theme.headline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    DemoPedalButton()
                }
                HStack(spacing: 12) {
                    RingGauge(pid: 0x0C, label: "Оберти", warnAbove: 6000)
                    RingGauge(pid: 0x05, label: "Т° рідини", warnAbove: 105)
                    RingGauge(pid: 0x42, label: "Напруга", warnBelow: 12.2, warnAbove: 15)
                }
            }
        }
        .frame(maxWidth: 520)
    }
}

/// Кругла шкала для одного параметра.
struct RingGauge: View {
    @EnvironmentObject var live: LiveStore
    let pid: UInt8
    let label: String
    var warnBelow: Double? = nil
    var warnAbove: Double? = nil

    var body: some View {
        let def = PIDTable.definition(pid)!
        let v = live.values[pid]
        let frac = v.map { min(1, max(0, ($0 - def.scaleMin) / (def.scaleMax - def.scaleMin))) } ?? 0
        let warn = v.map { x in (warnBelow.map { x < $0 } ?? false) || (warnAbove.map { x > $0 } ?? false) } ?? false
        let color = v == nil ? Theme.textTertiary : (warn ? Theme.warning : Theme.accent)
        VStack(spacing: 8) {
            ZStack {
                Circle().trim(from: 0.12, to: 0.88)
                    .stroke(Theme.cardRaised, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().trim(from: 0.12, to: 0.12 + 0.76 * frac)
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .animation(.easeOut(duration: 0.25), value: frac)
                VStack(spacing: 0) {
                    Text(v.map { def.format($0) } ?? "—").font(Theme.number(22)).foregroundStyle(Theme.textPrimary)
                    Text(def.unit).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 112, height: 112)
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Основні показники одним поглядом.
private struct KeyReadings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveStore
    private let pids: [UInt8] = [0x04, 0x06, 0x07, 0x10, 0x0B, 0x0F, 0x11, 0x0D, 0x5C, 0xF0]

    var body: some View {
        let items = pids.compactMap { PIDTable.definition($0) }.filter { model.isSupported($0.pid) }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Основні показники", systemImage: "list.bullet.below.rectangle")
                        .font(Theme.headline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Усі параметри →") { model.screen = .live }.buttonStyle(.link)
                }
                Text("Натисніть ⓘ біля параметра — там пояснення простими словами і норма. Жовтим підсвічено значення поза нормою.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(items) { def in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(def.shortName).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Spacer(minLength: 2)
                                PIDInfoButton(pid: def.pid)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(live.values[def.pid].map { def.format($0) } ?? "…")
                                    .font(Theme.number(18)).foregroundStyle(valueColor(def.pid, live.values[def.pid]))
                                Text(def.unit).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.cardRaised))
                    }
                }
            }
        }
    }
}

private struct ReadinessCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Готовність систем самоперевірки", systemImage: "checklist")
                        .help("Скільки систем авто вже перевірили себе. 7 з 7 — усі перевірки пройдені.").font(Theme.headline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if let m = model.monitor {
                        Text("\(m.completeCount)/\(m.monitors.count)").font(Theme.number(14)).foregroundStyle(Theme.textPrimary)
                    }
                }
                if let m = model.monitor, !m.monitors.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(m.monitors) { mon in
                            HStack(spacing: 6) {
                                Image(systemName: mon.complete ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(mon.complete ? Theme.ok : Theme.warning)
                                Text(mon.name).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            }
                        }
                    }
                    Text("«Не завершено» — система ще не перевірила себе після стирання помилок або відключення акумулятора. Це не несправність: потрібно проїхати кілька поїздок у різних режимах.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Авто не повідомило стан систем.").font(Theme.body).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

/// Кнопка збереження текстового звіту.
struct ReportButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            let name = model.vin?.brandKey ?? "авто"
            panel.nameFieldStringValue = "Діагностика \(name) \(Date().formatted(.dateTime.day().month().year())).txt"
            if panel.runModal() == .OK, let url = panel.url {
                do {
                    try model.reportText().write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    model.alertMessage = "Не вдалося зберегти звіт: \(error.localizedDescription)"
                }
            }
        } label: { Label("Зберегти звіт", systemImage: "square.and.arrow.down") }
        .buttonStyle(SubtleButtonStyle())
        .disabled(!model.connection.isConnected)
    }
}
#endif
