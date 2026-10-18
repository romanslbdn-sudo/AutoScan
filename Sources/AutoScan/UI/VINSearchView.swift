#if os(macOS)
import SwiftUI
import AutoScanCore

/// Пошук інформації про будь-яке авто за VIN-номером — без підключення до машини.
struct VINSearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""
    @State private var info: VINInfo?
    @State private var details: VehicleDetails?
    @State private var loading = false
    @State private var onlineFailed = false
    @AppStorage("vin.recent") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: ",").map(String.init) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Пошук за VIN",
                             subtitle: "Введіть VIN будь-якого авто — програма розшифрує його і знайде дані про модель і двигун")

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            TextField("17 символів, напр. WVWZZZ3CZEE123456", text: $input)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 15, design: .monospaced))
                                .onSubmit(search)
                                .onChange(of: input) { v in
                                    let clean = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(17))
                                    if clean != v { input = clean }
                                }
                            Text("\(input.count)/17").font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(input.count == 17 ? Theme.ok : Theme.textTertiary)
                            Button { search() } label: { Label("Знайти", systemImage: "magnifyingglass") }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(input.count != 17 || loading)
                        }
                        HStack(spacing: 8) {
                            if let v = model.vin?.vin {
                                Button("VIN підключеного авто") { input = v; search() }.buttonStyle(.link)
                            }
                            Text("VIN є в техпаспорті, під лобовим склом зліва, на стійці водійських дверей або під капотом.")
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        if !recent.isEmpty {
                            HStack(spacing: 6) {
                                Text("Нещодавні:").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                ForEach(recent.prefix(5), id: \.self) { r in
                                    Button(r) { input = r; search() }
                                        .buttonStyle(.link)
                                        .font(.system(size: 11, design: .monospaced))
                                }
                            }
                        }
                    }
                }

                if let info {
                    breakdown(info)
                    HStack(alignment: .top, spacing: 16) {
                        basics(info)
                        online
                    }
                }
            }
            .padding(28)
        }
    }

    private func search() {
        let v = String(input.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(17))
        guard v.count == 17 else { return }
        info = VINInfo(vin: v)
        details = nil
        onlineFailed = false
        var list = recent.filter { $0 != v }
        list.insert(v, at: 0)
        recentRaw = list.prefix(8).joined(separator: ",")
        guard let url = NHTSADecoder.url(vin: v) else { return }
        loading = true
        Task {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
                details = NHTSADecoder.parse(data)
                onlineFailed = details == nil
            } else {
                onlineFailed = true
            }
            loading = false
        }
    }

    // MARK: Розбір номера по частинах

    private func breakdown(_ i: VINInfo) -> some View {
        let colors: [Color] = [Theme.accent, Theme.info, Theme.warning, Theme.ok, Theme.textSecondary]
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Що означають символи").font(Theme.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if !i.isValidFormat {
                        Pill(text: "неправильний формат", color: Theme.danger, icon: "xmark")
                    } else if let ok = i.checkDigitValid {
                        Pill(text: ok ? "контрольна цифра вірна" : "контрольна цифра НЕ збігається", color: ok ? Theme.ok : Theme.danger,
                             icon: ok ? "checkmark" : "exclamationmark.triangle")
                    } else {
                        Pill(text: "формат вірний", color: Theme.ok, icon: "checkmark")
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(i.parts.enumerated()), id: \.offset) { idx, part in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(part.0)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(colors[idx % colors.count])
                            Rectangle().fill(colors[idx % colors.count]).frame(height: 3)
                            Text(part.1).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if i.checkDigitValid == false {
                    Text("Для авто американського ринку 9-й символ — контрольний. Якщо він не збігається, VIN, можливо, введено з помилкою — або номер підроблений. Перевірте ще раз.")
                        .font(Theme.caption).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if i.isValidFormat == false {
                    Text("У VIN не буває літер I, O, Q (щоб не плутати з 1 і 0) — перевірте, чи не введено їх замість цифр.")
                        .font(Theme.caption).foregroundStyle(Theme.warning)
                }
            }
        }
    }

    // MARK: Що відомо без інтернету

    private func basics(_ i: VINInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Розшифровка VIN", systemImage: "barcode.viewfinder").font(Theme.headline).foregroundStyle(Theme.textSecondary)
                InfoRow(label: "Виробник", value: i.manufacturer ?? "не визначено")
                if let b = i.brandInfo {
                    InfoRow(label: "Модель", value: b.model)
                    Text(b.detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                InfoRow(label: "Країна", value: i.country ?? "не визначено")
                InfoRow(label: "Модельний рік", value: i.yearText)
                if let note = i.yearNote {
                    Text(note).font(Theme.caption).foregroundStyle(i.modelYear == nil ? Theme.warning : Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                InfoRow(label: "Серійний номер", value: String(i.vin.suffix(6)), mono: true)
                Divider().overlay(Theme.stroke)
                Label(i.region.title, systemImage: "globe.europe.africa")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(i.region.explanation).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Стандарт визначено автоматично за першими символами. Працює без інтернету.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: 380)
    }

    // MARK: Онлайн-база

    @ViewBuilder private var online: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Модель і двигун (онлайн-база)", systemImage: "globe").font(Theme.headline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }
                if let d = details {
                    if let t = [d.make, d.model].compactMap({ $0 }).joined(separator: " ").nilIfEmptyUI {
                        Text(t).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    }
                    if let e = d.engineSummary {
                        Pill(text: e, color: Theme.accent, icon: "engine.combustion")
                    }
                    if let y = d.year { InfoRow(label: "Рік", value: "\(y)") }
                    if let x = d.displacementL { InfoRow(label: "Об'єм двигуна", value: String(format: "%.1f л", x).replacingOccurrences(of: ".", with: ",")) }
                    if let x = d.cylinders { InfoRow(label: "Циліндрів", value: "\(x)") }
                    if let x = d.powerText { InfoRow(label: "Потужність", value: x) }
                    if let x = d.fuel { InfoRow(label: "Паливо", value: x) }
                    if let x = d.turbo { InfoRow(label: "Турбіна", value: x ? "так" : "ні") }
                    if let x = d.engineCode { InfoRow(label: "Двигун", value: x) }
                    if let x = d.trim { InfoRow(label: "Комплектація", value: x) }
                    if let x = d.body { InfoRow(label: "Кузов", value: x) }
                    if let x = d.transmission { InfoRow(label: "Коробка", value: x) }
                    if let x = d.drive { InfoRow(label: "Привід", value: x) }
                    if let x = d.plant { InfoRow(label: "Завод", value: x) }
                    Text("Джерело: \(d.source). Найповніші дані — для авто американського ринку; для європейських частина полів може бути порожньою.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if onlineFailed {
                    Text("Онлайн-база не знайшла додаткових даних про цей VIN або немає інтернету. Для європейських авто це буває часто — розшифровка зліва все одно вірна.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !loading {
                    Text("Тут з'являться модель, двигун і комплектація.").font(Theme.body).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

private extension String {
    var nilIfEmptyUI: String? { isEmpty ? nil : self }
}
#endif
