#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AutoScanCore

/// Звіт для клієнта: стан до ремонту → що зроблено → стан після → PDF.
struct ClientReportView: View {
    @EnvironmentObject var model: AppModel
    @State private var job = ServiceJob.load()
    @State private var profile = ServiceProfile.load()
    @State private var confirmNew = false
    @State private var showProfile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Звіт клієнту",
                             subtitle: "PDF-акт: стан авто до ремонту, що зроблено, що замінено, і стан після") {
                    HStack(spacing: 8) {
                        Button { showProfile.toggle() } label: { Label("Дані сервісу", systemImage: "building.2") }
                            .buttonStyle(SubtleButtonStyle())
                        Button { confirmNew = true } label: { Label("Новий клієнт", systemImage: "person.badge.plus") }
                            .buttonStyle(SubtleButtonStyle())
                    }
                }

                if showProfile || profile.name.isEmpty { profileCard }

                stepCard(1, "Клієнт і авто", done: !job.clientName.isEmpty || !job.carTitle.isEmpty) { clientFields }
                stepCard(2, "Стан ДО ремонту", done: job.before != nil) {
                    snapshotPanel(job.before, isAfter: false)
                }
                stepCard(3, "Що зроблено", done: !job.works.isEmpty || !job.parts.isEmpty) { workFields }
                stepCard(4, "Стан ПІСЛЯ ремонту", done: job.after != nil) {
                    snapshotPanel(job.after, isAfter: true)
                }

                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.system(size: 22)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Готовий акт у PDF").font(Theme.headline).foregroundStyle(Theme.textPrimary)
                        Text("Можна створити на будь-якому кроці: лише діагностику або повний акт до/після.")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button { exportPDF() } label: { Label("Створити PDF", systemImage: "square.and.arrow.up") }
                        .buttonStyle(AccentButtonStyle())
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent.opacity(0.35)))
            }
            .padding(28)
        }
        .onChange(of: job) { $0.save() }
        .onChange(of: profile) { $0.save() }
        .confirmationDialog("Почати звіт для нового клієнта?", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("Почати новий", role: .destructive) { job = ServiceJob() }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Поточні дані клієнта, роботи і знімки стану буде очищено. Дані сервісу залишаться.")
        }
    }

    // MARK: Кроки

    private func stepCard<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(done ? Theme.ok.opacity(0.18) : Theme.cardRaised).frame(width: 28, height: 28)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ok)
                        } else {
                            Text("\(n)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Text(title).font(Theme.title).foregroundStyle(Theme.textPrimary)
                }
                content()
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func editor(_ label: String, _ text: Binding<String>, hint: String, height: CGFloat = 80) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
            TextEditor(text: text)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cardRaised))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke))
        }
    }

    private var profileCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Дані вашого сервісу (шапка акту)", systemImage: "building.2")
                    .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 12) {
                    field("Назва сервісу", $profile.name, prompt: "Напр. «Автодіагностика»")
                    field("Телефон", $profile.phone, prompt: "+380…")
                }
                HStack(spacing: 12) {
                    field("Адреса", $profile.address, prompt: "Місто, вулиця")
                    field("Майстер", $profile.master, prompt: "Ім'я майстра")
                }
                Text("Вводиться один раз і зберігається для всіх наступних актів.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var clientFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                field("Ім'я клієнта", $job.clientName)
                field("Телефон клієнта", $job.clientPhone, prompt: "+380…")
            }
            HStack(alignment: .bottom, spacing: 12) {
                field("Автомобіль", $job.carTitle, prompt: "Марка, модель, рік")
                Button("Взяти з діагностики") {
                    let guess = model.carTitleGuess
                    if !guess.isEmpty { job.carTitle = guess }
                    if let v = model.vin?.vin { job.vin = v }
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(!model.connection.isConnected)
            }
            HStack(spacing: 12) {
                field("Держномер", $job.plate, prompt: "AT 0000 XX")
                field("Пробіг, км", $job.mileage)
                field("VIN", $job.vin)
            }
            editor("Звернення клієнта (на що скаржиться)", $job.complaint, hint: "необов'язково", height: 54)
        }
    }

    private var workFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            editor("Виконані роботи", $job.works, hint: "кожен пункт — з нового рядка")
            editor("Замінені запчастини", $job.parts, hint: "напр. «Свічки запалювання NGK — 4 шт.»")
            editor("Рекомендації клієнту", $job.recommendations, hint: "необов'язково", height: 60)
        }
    }

    @ViewBuilder
    private func snapshotPanel(_ snap: DiagnosticSnapshot?, isAfter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snap {
                HStack(spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(Theme.textTertiary)
                    Text("Зафіксовано \(snap.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Видалити") {
                        if isAfter { job.after = nil } else { job.before = nil }
                    }
                    .buttonStyle(.link)
                }
                if snap.codes.isEmpty {
                    Label("Помилок не виявлено", systemImage: "checkmark.seal.fill")
                        .font(Theme.headline).foregroundStyle(Theme.ok)
                } else {
                    FlowCodes(codes: snap.codes)
                }
                if isAfter, let before = job.before {
                    let fixed = before.codeSet.subtracting(snap.codeSet).sorted()
                    let left = before.codeSet.intersection(snap.codeSet).sorted()
                    HStack(spacing: 8) {
                        if !fixed.isEmpty { Pill(text: "Усунено: " + fixed.joined(separator: ", "), color: Theme.ok, icon: "checkmark") }
                        if !left.isEmpty { Pill(text: "Залишилось: " + left.joined(separator: ", "), color: Theme.warning, icon: "exclamationmark") }
                    }
                }
                Text("\(snap.readings.count) показників датчиків · \(snap.checks.filter(\.problem).count) відхилень від норми")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            } else {
                Text(isAfter
                     ? "Після ремонту: зітріть помилки (екран «Помилки»), заведіть двигун, дайте попрацювати кілька хвилин — і зафіксуйте стан."
                     : "Підключіться до авто перед ремонтом і зафіксуйте, які помилки і показники були.")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    let s = model.makeSnapshot()
                    if isAfter { job.after = s } else { job.before = s }
                    if job.carTitle.isEmpty { job.carTitle = model.carTitleGuess }
                    if job.vin.isEmpty, let v = model.vin?.vin { job.vin = v }
                } label: {
                    Label(snap == nil ? (isAfter ? "Зафіксувати стан ПІСЛЯ" : "Зафіксувати стан ДО")
                                      : "Зафіксувати заново",
                          systemImage: "camera.metering.matrix")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!model.connection.isConnected)
                if !model.connection.isConnected {
                    Text("Спершу підключіться до авто").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: PDF

    private func exportPDF() {
        let data = ReportPDF.make(job: job, profile: profile)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let who = [job.carTitle.components(separatedBy: ",").first ?? "", job.plate, job.clientName]
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        panel.nameFieldStringValue = "Акт \(who.isEmpty ? "" : who + " ")\(Date().formatted(.dateTime.day().month(.twoDigits).year())).pdf"
            .replacingOccurrences(of: "/", with: "-")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                model.alertMessage = "Не вдалося зберегти PDF: \(error.localizedDescription)"
            }
        }
    }
}

/// Коди помилок «плиточками».
private struct FlowCodes: View {
    let codes: [DiagnosticSnapshot.Code]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Set(codes.map(\.code))).sorted(), id: \.self) { c in
                let item = codes.first { $0.code == c }!
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.severityColor(item.severity)).frame(width: 4, height: 16)
                    Text(c).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    Text(item.title).font(Theme.body).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
    }
}
#endif
