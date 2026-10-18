#if os(macOS)
import SwiftUI
import AutoScanCore

/// Кольори та шрифти програми — єдиний стиль на всіх екранах.
enum ThemeMode: String, CaseIterable {
    case dark, night
    var title: String { self == .dark ? "Темний" : "Нічний" }
}

enum Theme {
    /// Поточний режим. Змінюється перемикачем; вікно після цього перемальовується повністю.
    static var mode: ThemeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme.mode") ?? "") ?? .dark
    private static var night: Bool { mode == .night }

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    // «Нічний» — майже чорний фон, приглушений текст і менш насичені кольори
    static var background: Color { night ? c(0.035, 0.039, 0.047) : c(0.067, 0.075, 0.094) }
    static var sidebar: Color { night ? c(0.051, 0.055, 0.066) : c(0.086, 0.094, 0.118) }
    static var card: Color { night ? c(0.075, 0.082, 0.096) : c(0.118, 0.129, 0.157) }
    static var cardRaised: Color { night ? c(0.098, 0.106, 0.122) : c(0.145, 0.157, 0.192) }
    static var stroke: Color { Color.white.opacity(night ? 0.045 : 0.07) }

    static var textPrimary: Color { night ? c(0.78, 0.79, 0.81) : c(0.93, 0.94, 0.96) }
    static var textSecondary: Color { night ? c(0.50, 0.52, 0.56) : c(0.60, 0.63, 0.69) }
    static var textTertiary: Color { night ? c(0.34, 0.36, 0.40) : c(0.42, 0.45, 0.51) }

    static var accent: Color { night ? c(0.27, 0.62, 0.58) : c(0.25, 0.82, 0.76) }
    static var ok: Color { night ? c(0.33, 0.64, 0.45) : c(0.33, 0.84, 0.52) }
    static var warning: Color { night ? c(0.85, 0.63, 0.30) : c(1.00, 0.73, 0.27) }
    static var danger: Color { night ? c(0.85, 0.40, 0.40) : c(1.00, 0.38, 0.38) }
    static var info: Color { night ? c(0.42, 0.55, 0.82) : c(0.42, 0.62, 1.00) }

    static func severityColor(_ s: Int) -> Color {
        switch s {
        case 3: return danger
        case 2: return warning
        default: return info
        }
    }

    static func verdictColor(_ v: NormVerdict) -> Color {
        switch v {
        case .normal: return ok
        case .waiting: return textSecondary
        case .low, .high, .unstable: return warning
        case .absent: return danger
        }
    }

    static func kindColor(_ k: DTCKind) -> Color {
        switch k {
        case .stored: return danger
        case .pending: return warning
        case .permanent: return info
        }
    }

    // Шрифти
    static let largeTitle = Font.system(size: 26, weight: .bold, design: .default)
    static let title = Font.system(size: 18, weight: .semibold)
    static let headline = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    static let code = Font.system(size: 20, weight: .bold, design: .monospaced)
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded).monospacedDigit() }
}

/// Картка з м'яким фоном і рамкою.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// Невелика кольорова «пігулка» зі статусом.
struct Pill: View {
    let text: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Заголовок екрана.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.largeTitle).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            trailing
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Порожній стан екрана з іконкою і поясненням.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text(title).font(Theme.title).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct AccentButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(Color.black.opacity(0.85))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}

struct SubtleButtonStyle: ButtonStyle {
    var color: Color = Theme.textPrimary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardRaised.opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// Педаль газу для демо-режиму: тримаєте — оберти ростуть, відпускаєте — падають.
struct DemoPedalButton: View {
    @EnvironmentObject var model: AppModel
    @State private var level: Double = 0
    @State private var pressing = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        if model.isDemo {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardRaised)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.ok, Theme.warning, Theme.danger], startPoint: .leading, endPoint: .trailing))
                        .opacity(0.85)
                        .frame(width: max(0, 170 * level))
                    HStack(spacing: 6) {
                        Image(systemName: "pedal.accelerator.fill")
                        Text(pressing ? "Газ: \(Int(level * 100)) %" : "Тримайте — газ").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                }
                .frame(width: 170, height: 34)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressing { press() } }
                    .onEnded { _ in release() })
                .help("Демо: тримайте кнопку — двигун набирає оберти, відпустіть — газ скинуто")
            }
        }
    }

    private func press() {
        pressing = true
        task?.cancel()
        task = Task { @MainActor in
            while pressing && !Task.isCancelled {
                level = min(1, level + 0.035)
                model.demoPedal(level)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func release() {
        pressing = false
        task?.cancel()
        model.demoPedal(nil)
        task = Task { @MainActor in
            while level > 0 && !Task.isCancelled {
                level = max(0, level - 0.08)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }
}

/// Кнопка «ⓘ» з поясненням параметра простими словами.
struct PIDInfoButton: View {
    let pid: UInt8
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Що це за параметр?")
        .popover(isPresented: $show, arrowEdge: .bottom) { PIDHelpView(pid: pid) }
    }
}

struct PIDHelpView: View {
    let pid: UInt8
    var body: some View {
        let def = PIDTable.definition(pid)
        let help = PIDHelp.of(pid)
        VStack(alignment: .leading, spacing: 10) {
            Text(def?.name ?? "").font(Theme.headline)
            Text(help.what).font(Theme.body).fixedSize(horizontal: false, vertical: true)
            if let n = help.normal {
                Label {
                    Text(n).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "checkmark.circle").foregroundStyle(Theme.ok) }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Колір значення: попереджувальний, якщо воно поза нормою.
func valueColor(_ pid: UInt8, _ value: Double?) -> Color {
    guard let v = value, let r = PIDHelp.of(pid).range else { return Theme.textPrimary }
    // Для температури рідини холодний двигун — не несправність, тож перевіряємо лише перегрів
    if pid == 0x05 || pid == 0x67 { return v > r.upperBound ? Theme.danger : Theme.textPrimary }
    return r.contains(v) ? Theme.textPrimary : Theme.warning
}

/// Підпис + значення в один рядок.
struct InfoRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.body).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .system(size: 13, design: .monospaced) : Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif
