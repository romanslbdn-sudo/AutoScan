#if os(macOS)
import SwiftUI
import Charts
import AutoScanCore

struct NormView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.connection.isConnected {
            NotConnectedView()
        } else if model.dtcs.isEmpty {
            EmptyStateView(icon: "checkmark.seal",
                           title: "Помилок немає — порівнювати нічого",
                           message: "Тут з'являтиметься порівняння «як має бути» і «як зараз» для сигналів, пов'язаних зі знайденими помилками.",
                           actionTitle: "Прочитати помилки ще раз") { Task { await model.readDTCs() } }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ScreenHeader(title: "Норма vs зараз",
                                 subtitle: "Тільки для знайдених помилок: як сигнал має виглядати і що датчик показує зараз") {
                        Button { model.resetHistory() } label: { Label("Почати заміри заново", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(SubtleButtonStyle())
                    }

                    ForEach(model.uniqueCodes, id: \.self) { code in
                        CodeNormSection(code: code)
                    }

                    Text("Норми — типові значення для більшості легкових авто. Для конкретного двигуна вони можуть трохи відрізнятися. Програма показує те, що авто передає через OBD2; точну форму імпульсів (осцилограму) можна побачити лише осцилографом.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
            }
        }
    }
}

private struct CodeNormSection: View {
    @EnvironmentObject var model: AppModel
    let code: String

    var body: some View {
        let entry = model.database.lookup(code, brand: model.brand).entry
        let checks = NormRules.checks(for: code)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(code).font(Theme.code).foregroundStyle(Theme.textPrimary)
                Text(entry.title).font(Theme.title).foregroundStyle(Theme.textPrimary)
                Spacer()
                summaryPill(checks)
            }
            if checks.isEmpty {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle").foregroundStyle(Theme.info)
                        Text("Для цього коду немає сигналу, який можна порівняти через OBD2. Дивіться причини на екрані «Помилки».")
                            .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("До помилок") { model.screen = .faults }.buttonStyle(SubtleButtonStyle())
                    }
                }
            } else {
                ForEach(checks) { check in
                    NormCheckCard(check: check)
                }
            }
        }
    }

    @ViewBuilder private func summaryPill(_ checks: [NormCheck]) -> some View {
        let ctx = model.normContext
        let results = checks.map { $0.evaluate(ctx).verdict }
        let problems = results.filter(\.isProblem).count
        if checks.isEmpty {
            EmptyView()
        } else if problems > 0 {
            Pill(text: "відхилень: \(problems)", color: Theme.warning, icon: "exclamationmark.triangle.fill")
        } else if results.allSatisfy({ $0 == .waiting }) {
            Pill(text: "чекаю умов перевірки", color: Theme.textSecondary, icon: "hourglass")
        } else {
            Pill(text: "сигнали в нормі", color: Theme.ok, icon: "checkmark")
        }
    }
}

struct NormCheckCard: View {
    @EnvironmentObject var model: AppModel
    let check: NormCheck

    var body: some View {
        let result = check.evaluate(model.normContext)
        let color = Theme.verdictColor(result.verdict)
        let def = PIDTable.definition(check.pid)
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(check.title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Pill(text: result.verdict.title, color: color, icon: icon(result.verdict))
                }

                HStack(alignment: .top, spacing: 14) {
                    // Як має бути
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Як має бути", systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ok)
                        ExpectedSignalView(shape: check.shape)
                            .frame(height: 92)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardRaised))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(check.expected).font(Theme.body).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 60)

                    // Як зараз
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Як зараз", systemImage: "waveform.path")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Theme.cardRaised)
                            let hist = model.history[check.pid] ?? []
                            if hist.count >= 2 {
                                Sparkline(values: hist.suffix(80).map { $0 },
                                          color: color == Theme.textSecondary ? Theme.accent : color,
                                          band: check.shape == .pulses ? nil : check.lo...check.hi,
                                          yDomain: domain(def))
                                    .padding(8)
                            } else if result.verdict == .absent {
                                VStack(spacing: 4) {
                                    Rectangle().fill(Theme.danger.opacity(0.7)).frame(height: 2).padding(.horizontal, 16)
                                    Text("сигналу немає").font(Theme.caption).foregroundStyle(Theme.danger)
                                }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        HStack(alignment: .firstTextBaseline) {
                            Text(result.actualText).font(Theme.number(16)).foregroundStyle(Theme.textPrimary)
                            if check.shape == .pulses {
                                Text("(оберти, які бачить блок)").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.verdict == .normal ? "lightbulb" : (result.verdict == .waiting ? "hand.point.right" : "exclamationmark.bubble"))
                        .foregroundStyle(color)
                    Text(result.explanation).font(Theme.body).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.09)))

                Label("Умова перевірки: \(check.condition)", systemImage: "info.circle")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func domain(_ def: PIDDefinition?) -> ClosedRange<Double>? {
        guard let def else { return nil }
        let hist = model.history[check.pid] ?? []
        var lo = min(check.lo, hist.min() ?? check.lo)
        var hi = max(check.hi, hist.max() ?? check.hi)
        if check.shape == .pulses { lo = 0; hi = max(hi, 1200) }
        let pad = (hi - lo) * 0.15
        lo = max(def.scaleMin, lo - pad)
        hi = min(def.scaleMax, hi + pad)
        return lo < hi ? lo...hi : nil
    }

    private func icon(_ v: NormVerdict) -> String {
        switch v {
        case .normal: return "checkmark"
        case .low: return "arrow.down"
        case .high: return "arrow.up"
        case .absent: return "xmark"
        case .unstable: return "waveform"
        case .waiting: return "hourglass"
        }
    }
}

/// Схематичний малюнок «як має виглядати сигнал».
struct ExpectedSignalView: View {
    let shape: SignalShape

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let pad: CGFloat = 12
            let top = pad + 4, bottom = h - pad - 4
            var path = Path()
            switch shape {
            case .steady:
                let band = CGRect(x: pad, y: h * 0.32, width: w - pad * 2, height: h * 0.36)
                ctx.fill(Path(roundedRect: band, cornerRadius: 4), with: .color(Theme.ok.opacity(0.13)))
                let mid = h * 0.5
                path.move(to: CGPoint(x: pad, y: mid))
                var x = pad
                while x <= w - pad {
                    let y = mid + sin(x / 9) * 2.5 + sin(x / 3.7) * 1.2
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 2
                }
            case .switching:
                var x = pad
                path.move(to: CGPoint(x: pad, y: (top + bottom) / 2))
                while x <= w - pad {
                    let phase = (x - pad) / 26
                    // Майже прямокутна хвиля: швидкі перемикання між 0,1 і 0,9 В
                    let s = CGFloat(tanh(sin(Double(phase)) * 3))
                    let y = (top + bottom) / 2 - s * (bottom - top) / 2
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 1.5
                }
                for (label, y) in [("0,9 В", top), ("0,1 В", bottom)] {
                    ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(Theme.textTertiary),
                             at: CGPoint(x: w - pad - 14, y: y), anchor: .center)
                }
            case .pulses:
                // Імпульси від зубів диска з пропуском (мітка ВМТ)
                let tooth: CGFloat = 7
                var x = pad
                var n = 0
                path.move(to: CGPoint(x: x, y: bottom))
                while x + tooth <= w - pad {
                    let gap = n % 14 == 12 || n % 14 == 13
                    if !gap {
                        path.addLine(to: CGPoint(x: x, y: top))
                        path.addLine(to: CGPoint(x: x + tooth / 2, y: top))
                        path.addLine(to: CGPoint(x: x + tooth / 2, y: bottom))
                    }
                    path.addLine(to: CGPoint(x: x + tooth, y: bottom))
                    x += tooth
                    n += 1
                }
            }
            ctx.stroke(path, with: .color(Theme.ok), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}
#endif
