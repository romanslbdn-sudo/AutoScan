#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AutoScanCore

struct PacksView: View {
    @EnvironmentObject var model: AppModel
    @State private var brandField = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Бази авто", subtitle: "Описи помилок: загальна база + пакети під конкретні марки") {
                    HStack(spacing: 8) {
                        Button { saveTemplate() } label: { Label("Шаблон пакета", systemImage: "doc.badge.plus") }
                            .buttonStyle(SubtleButtonStyle())
                        Button { importPack() } label: { Label("Завантажити пакет…", systemImage: "square.and.arrow.down.on.square") }
                            .buttonStyle(AccentButtonStyle())
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Загальна база OBD2", systemImage: "books.vertical.fill")
                                .font(Theme.headline).foregroundStyle(Theme.textSecondary)
                            Text("\(model.database.genericCount)").font(Theme.number(34)).foregroundStyle(Theme.textPrimary)
                            Text("кодів з поясненнями українською — однакові для всіх марок (стандарт SAE). Вбудована в програму.")
                                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Марка поточного авто", systemImage: "car.fill")
                                .font(Theme.headline).foregroundStyle(Theme.textSecondary)
                            Text(model.brand ?? "Не визначено").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
                            Text(model.manualBrand.isEmpty
                                 ? (model.vin?.brandKey != nil ? "Визначено за VIN-кодом." : "VIN не отримано — вкажіть марку вручну.")
                                 : "Вказано вручну.")
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            HStack {
                                TextField("Напр. Volkswagen", text: $brandField)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { model.manualBrand = brandField.trimmingCharacters(in: .whitespaces) }
                                Button("Вказати") { model.manualBrand = brandField.trimmingCharacters(in: .whitespaces) }
                                    .buttonStyle(SubtleButtonStyle())
                                if !model.manualBrand.isEmpty {
                                    Button("Скинути") { model.manualBrand = ""; brandField = "" }
                                        .buttonStyle(SubtleButtonStyle())
                                }
                            }
                        }
                    }
                }

                Text("Завантажені пакети").font(Theme.title).foregroundStyle(Theme.textPrimary).padding(.top, 6)

                if model.packs.isEmpty {
                    Card {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "shippingbox").font(.system(size: 30)).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Пакетів ще немає").font(Theme.headline).foregroundStyle(Theme.textPrimary)
                                Text("Пакет — це файл .json із заводськими кодами (P1xxx, U1xxx тощо) і примітками для конкретної марки. Коли пакет завантажено, програма сама підбирає його за VIN-кодом авто. Щоб створити свій пакет, збережіть шаблон, заповніть його і завантажте.")
                                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    ForEach(model.packs) { pack in
                        PackRow(pack: pack, active: pack.applies(toBrand: model.brand))
                    }
                }
            }
            .padding(28)
        }
        .onAppear { brandField = model.manualBrand }
    }

    private func importPack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Виберіть файл пакета AutoScan (.json)"
        if panel.runModal() == .OK {
            for url in panel.urls { model.importPack(url: url) }
        }
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "шаблон-пакета-AutoScan.json"
        if panel.runModal() == .OK, let url = panel.url {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try enc.encode(BrandPack.template).write(to: url)
            } catch {
                model.alertMessage = "Не вдалося зберегти шаблон: \(error.localizedDescription)"
            }
        }
    }
}

private struct PackRow: View {
    @EnvironmentObject var model: AppModel
    let pack: BrandPack
    let active: Bool
    @State private var confirmRemove = false

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(active ? Theme.accent.opacity(0.15) : Theme.cardRaised).frame(width: 46, height: 46)
                    Text(String(pack.brand.prefix(2)).uppercased()).font(.system(size: 15, weight: .bold))
                        .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(pack.title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                        if active { Pill(text: "для цього авто", color: Theme.accent, icon: "checkmark") }
                    }
                    Text("\(pack.brand) · версія \(pack.version) · \(pack.codes.count) кодів")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    if let n = pack.notes, !n.isEmpty {
                        Text(n).font(Theme.body).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button { confirmRemove = true } label: { Image(systemName: "trash") }
                    .buttonStyle(SubtleButtonStyle(color: Theme.danger))
                    .help("Видалити пакет")
            }
        }
        .confirmationDialog("Видалити пакет «\(pack.title)»?", isPresented: $confirmRemove) {
            Button("Видалити", role: .destructive) { model.removePack(pack) }
            Button("Скасувати", role: .cancel) {}
        }
    }
}
#endif
