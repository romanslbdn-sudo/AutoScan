#if os(macOS)
import SwiftUI
import AutoScanCore

/// Старі авто (до OBD2): читання кодів миганням лампи.
struct RetroView: View {
    @AppStorage("retro.system") private var systemID = RetroSystems.all[0].id
    @State private var found: [String] = []
    @State private var digits: [Int] = []
    @State private var flashes = 0
    @State private var manual = ""

    private var system: RetroSystem { RetroSystems.all.first { $0.id == systemID } ?? RetroSystems.all[0] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Старі авто (до 1996)",
                             subtitle: "Машини до OBD2 показують коди помилок миганням лампи — адаптер не потрібен")

                // Вибір системи
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(RetroSystems.all) { s in
                        Button {
                            systemID = s.id
                            found = []; digits = []; flashes = 0
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                                Text(s.years).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(systemID == s.id ? Theme.cardRaised : Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(systemID == s.id ? Theme.accent : Theme.stroke, lineWidth: systemID == s.id ? 1.5 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    instructions.frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        counter
                        results
                    }
                    .frame(width: 380)
                }
            }
            .padding(28)
        }
    }

    // MARK: Інструкція

    private var instructions: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text(system.title).font(Theme.title).foregroundStyle(Theme.textPrimary)
                Text(system.cars).font(Theme.body).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label {
                    Text(system.connector).font(Theme.body).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "powerplug").foregroundStyle(Theme.accent) }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Що зробити").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    ForEach(Array(system.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Theme.accent.opacity(0.18)))
                                .foregroundStyle(Theme.accent)
                            Text(step).font(Theme.body).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Label {
                    Text(system.howToRead).font(Theme.body).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "lightbulb").foregroundStyle(Theme.warning) }

                if let w = system.warning {
                    Label {
                        Text(w).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
                }
                if let n = system.notes {
                    Label {
                        Text(n).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "info.circle").foregroundStyle(Theme.info) }
                }
                Label("Не підключайте перемички до інших виводів, ніж вказано, — можна пошкодити блок керування.", systemImage: "hand.raised")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Лічильник спалахів

    private var counter: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Лічильник спалахів").font(Theme.headline).foregroundStyle(Theme.textPrimary)
                if system.digits > 0 {
                    Text("Натискайте «Спалах» на кожне блимання. Коли лампа робить паузу — «Наступна цифра».")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(0..<system.digits, id: \.self) { i in
                            let text: String = i < digits.count ? "\(digits[i])" : (i == digits.count && flashes > 0 ? "\(flashes)" : "–")
                            Text(text)
                                .font(.system(size: 26, weight: .bold, design: .monospaced))
                                .frame(width: 46, height: 54)
                                .foregroundStyle(i == digits.count ? Theme.accent : Theme.textPrimary)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardRaised))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(i == digits.count ? Theme.accent : Theme.stroke))
                        }
                    }
                    HStack(spacing: 8) {
                        Button { flashes += 1 } label: {
                            Label("Спалах", systemImage: "light.max").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.space, modifiers: [])
                        Button { nextDigit() } label: { Text("Наступна цифра").frame(maxWidth: .infinity) }
                            .buttonStyle(SubtleButtonStyle())
                            .keyboardShortcut(.return, modifiers: [])
                            .disabled(flashes == 0)
                    }
                    HStack {
                        Text("Пробіл — спалах, Enter — наступна цифра").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button("Скинути") { digits = []; flashes = 0 }.buttonStyle(.link).font(Theme.caption)
                    }
                }
                Divider().overlay(Theme.stroke)
                HStack(spacing: 8) {
                    TextField(system.digits == 4 ? "Напр. 1223" : "Напр. 21", text: $manual)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addManual)
                    Button("Додати код", action: addManual).buttonStyle(SubtleButtonStyle())
                        .disabled(manual.filter(\.isNumber).isEmpty)
                }
            }
        }
    }

    private func nextDigit() {
        guard flashes > 0 else { return }
        // Нуль на лампі показують 10 спалахами
        digits.append(flashes >= 10 ? 0 : flashes)
        flashes = 0
        if digits.count >= system.digits {
            add(digits.map(String.init).joined())
            digits = []
        }
    }

    private func addManual() {
        let c = manual.filter(\.isNumber)
        guard !c.isEmpty else { return }
        add(c)
        manual = ""
    }

    private func add(_ code: String) {
        if !found.contains(code) { found.append(code) }
    }

    // MARK: Результат

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            if found.isEmpty {
                Card {
                    Text("Тут з'являться розшифровані коди.")
                        .font(Theme.body).foregroundStyle(Theme.textTertiary)
                }
            }
            ForEach(found, id: \.self) { c in
                let entry = system.lookup(c)
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(c).font(Theme.code).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button { found.removeAll { $0 == c } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                        }
                        if let e = entry {
                            Text(e.title).font(Theme.headline)
                                .foregroundStyle(e.isInfo ? Theme.ok : Theme.textPrimary)
                            Text(e.details).font(Theme.body).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !e.causes.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(e.causes.enumerated()), id: \.offset) { i, cause in
                                        Text("\(i + 1). \(cause)").font(Theme.body).foregroundStyle(Theme.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            if !e.isInfo {
                                Pill(text: e.severity >= 3 ? "Серйозно" : (e.severity == 2 ? "Перевірити найближчим часом" : "Не критично"),
                                     color: Theme.severityColor(e.severity))
                            }
                        } else {
                            Text("Такого коду немає в базі для «\(system.title)». Перевірте, чи правильно пораховані спалахи, і що вибрана правильна система.")
                                .font(Theme.body).foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
#endif
