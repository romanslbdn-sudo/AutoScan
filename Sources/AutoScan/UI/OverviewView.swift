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

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Автомобіль", systemImage: "car.fill").font(Theme.headline).foregroundStyle(Theme.textSecondary)
                if let v = model.vin {
                    Text(v.manufacturer ?? "Марку не визначено")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    VStack(spacing: 8) {
                        InfoRow(label: "VIN", value: v.vin, mono: true)
                        if let y = v.modelYear { InfoRow(label: "Модельний рік", value: "\(y)") }
                        if let c = v.country { InfoRow(label: "Країна виробництва", value: c) }
                    }
                } else {
                    Text("VIN не отримано").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Деякі авто (особливо до 2005 р.) не передають VIN через OBD2. Марку можна вказати вручну в розділі «Бази авто».")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(Theme.stroke)
                VStack(spacing: 8) {
                    InfoRow(label: "Адаптер", value: model.connInfo.adapterVersion.isEmpty ? model.adapterName : model.connInfo.adapterVersion)
                    InfoRow(label: "Протокол", value: model.connInfo.protocolName)
                    InfoRow(label: "Параметрів доступно", value: "\(model.supportedPIDs.count)")
                }
            }
        }
    }
}

private struct StatusCard: View {
    @EnvironmentObject var model: AppModel

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
                    }
                }
            }
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
                Label("Зараз", systemImage: "speedometer").font(Theme.headline).foregroundStyle(Theme.textSecondary)
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

private struct ReadinessCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Готовність систем самоперевірки", systemImage: "checklist").font(Theme.headline).foregroundStyle(Theme.textSecondary)
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
