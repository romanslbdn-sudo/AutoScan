#if os(macOS)
import SwiftUI
import AutoScanCore

struct LiveDataView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPicker = false
    @AppStorage("live.listMode") private var listMode = false

    /// Вибрані параметри, які авто реально передає, — спершу; решта в кінці.
    private var shown: [UInt8] {
        let sel = model.selectedPIDs
        return sel.filter { model.isSupported($0) } + sel.filter { !model.isSupported($0) }
    }

    private var availableCount: Int {
        PIDTable.all.filter { model.isSupported($0.pid) }.count
    }

    var body: some View {
        if !model.connection.isConnected {
            NotConnectedView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Живі дані",
                                 subtitle: "Показано \(model.selectedPIDs.filter { model.isSupported($0) }.count) з \(availableCount) параметрів, які передає це авто") {
                        HStack(spacing: 8) {
                            Picker("", selection: $listMode) {
                                Image(systemName: "square.grid.2x2").tag(false)
                                Image(systemName: "list.bullet").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 84)
                            .help("Плитки або компактний список")
                            SmoothingToggle()
                            DemoPedalButton()
                            Button {
                                model.livePaused.toggle()
                            } label: {
                                Label(model.livePaused ? "Продовжити" : "Пауза", systemImage: model.livePaused ? "play.fill" : "pause.fill")
                            }
                            .buttonStyle(SubtleButtonStyle())
                            Button { model.resetHistory() } label: { Label("Очистити", systemImage: "eraser") }
                                .buttonStyle(SubtleButtonStyle())
                            Button { selectAll() } label: { Label("Усі доступні", systemImage: "checklist.checked") }
                                .buttonStyle(SubtleButtonStyle())
                                .help("Показати всі параметри, які передає це авто")
                            Button { showPicker = true } label: { Label("Параметри", systemImage: "slider.horizontal.3") }
                                .buttonStyle(AccentButtonStyle())
                                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                                    PIDPicker().environmentObject(model)
                                }
                        }
                    }

                    if model.selectedPIDs.isEmpty {
                        EmptyStateView(icon: "slider.horizontal.3", title: "Параметри не вибрано",
                                       message: "Натисніть «Усі доступні» або «Параметри» і виберіть, які показники дивитися.",
                                       actionTitle: "Показати всі доступні") { selectAll() }
                    } else if listMode {
                        // Компактний список: десятки параметрів на одному екрані
                        VStack(spacing: 0) {
                            ForEach(PIDCategory.allCases, id: \.self) { cat in
                                let items = shown.compactMap { PIDTable.definition($0) }.filter { $0.category == cat }
                                if !items.isEmpty {
                                    Text(cat.rawValue.uppercased())
                                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.textTertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                                    ForEach(items) { def in
                                        PIDRow(def: def, supported: model.isSupported(def.pid))
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                            ForEach(shown, id: \.self) { pid in
                                if let def = PIDTable.definition(pid) {
                                    PIDTile(def: def, supported: model.isSupported(pid))
                                }
                            }
                        }
                    }

                    Text(model.connInfo.isCAN
                         ? "Швидкий режим: програма запитує до 6 параметрів одночасно. Навіть із усіма параметрами значення оновлюються кілька разів на секунду."
                         : "Старий протокол (K-Line) повільніший: що більше параметрів вибрано, то рідше оновлюється кожен.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(28)
            }
        }
    }

    private func selectAll() {
        model.selectedPIDs = PIDTable.all.map(\.pid).filter { model.isSupported($0) }
    }
}

/// Перемикач згладжування значень.
struct SmoothingToggle: View {
    @EnvironmentObject var live: LiveStore
    @State private var on = UserDefaults.standard.object(forKey: "live.smoothing") as? Bool ?? true

    var body: some View {
        Toggle(isOn: $on) { Text("Згладжування").font(.system(size: 12)) }
            .toggleStyle(.checkbox)
            .onChange(of: on) { live.smoothing = $0 }
            .help("Прибирає дрібне «тремтіння» цифр і графіків. Лямбда-зонди й оберти завжди показуються без згладжування — їхні швидкі зміни важливі для діагностики.")
    }
}

/// Один параметр рядком (для компактного списку).
struct PIDRow: View {
    @EnvironmentObject var live: LiveStore
    let def: PIDDefinition
    let supported: Bool

    var body: some View {
        let value = live.values[def.pid]
        let hist = live.history[def.pid] ?? []
        HStack(spacing: 12) {
            PIDInfoButton(pid: def.pid)
            VStack(alignment: .leading, spacing: 1) {
                Text(def.name).font(.system(size: 12.5)).foregroundStyle(supported ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                if let mn = hist.min(), let mx = hist.max(), hist.count > 2 {
                    Text("мін \(def.format(mn)) · макс \(def.format(mx))")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if supported {
                Sparkline(values: hist, color: Theme.accent, minSpan: def.minChartSpan)
                    .frame(width: 140, height: 24)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(supported ? (value.map { def.format($0) } ?? "…") : "—")
                    .font(Theme.number(15)).foregroundStyle(valueColor(def.pid, value))
                Text(def.unit).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct PIDTile: View {
    @EnvironmentObject var live: LiveStore
    let def: PIDDefinition
    let supported: Bool

    var body: some View {
        let value = live.values[def.pid]
        let hist = live.history[def.pid] ?? []
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(def.shortName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    PIDInfoButton(pid: def.pid)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(supported ? (value.map { def.format($0) } ?? "…") : "—")
                        .font(Theme.number(30)).foregroundStyle(valueColor(def.pid, value))
                    Text(def.unit).font(Theme.body).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if let mn = hist.min(), let mx = hist.max(), hist.count > 2 {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("макс \(def.format(mx))").font(.system(size: 10).monospacedDigit())
                            Text("мін \(def.format(mn))").font(.system(size: 10).monospacedDigit())
                        }
                        .foregroundStyle(Theme.textTertiary)
                    }
                }
                if supported {
                    Sparkline(values: hist, color: Theme.accent, minSpan: def.minChartSpan)
                        .frame(height: 54)
                } else {
                    Text("Це авто не передає цей параметр").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .frame(height: 54)
                }
                Text(def.name).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
    }
}

/// Маленький графік історії значень.
/// Малюється одним контуром через Canvas — у рази легше за Swift Charts,
/// тому не навантажує вбудовану графіку Intel.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent
    var band: ClosedRange<Double>? = nil
    var yDomain: ClosedRange<Double>? = nil
    /// Мінімальна висота шкали: дрібні коливання не розтягуються на весь графік.
    var minSpan: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let pts = Self.downsample(values, to: Int(size.width / 3))
            let dom = domain
            let span = max(dom.upperBound - dom.lowerBound, 0.000_001)
            func y(_ v: Double) -> CGFloat { size.height * CGFloat(1 - (v - dom.lowerBound) / span) }

            if let band {
                let top = y(min(band.upperBound, dom.upperBound))
                let bottom = y(max(band.lowerBound, dom.lowerBound))
                ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: max(0, bottom - top))),
                         with: .color(Theme.ok.opacity(0.12)))
            }
            guard pts.count >= 2 else { return }
            let step = size.width / CGFloat(pts.count - 1)
            // Плавна крива через середини відрізків
            let points = pts.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: y($0.element)) }
            var line = Path()
            line.move(to: points[0])
            for i in 1..<points.count {
                let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                line.addQuadCurve(to: mid, control: points[i - 1])
            }
            line.addLine(to: points[points.count - 1])
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.26), color.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }

    /// Не більше однієї точки на ~3 пікселі ширини.
    static func downsample(_ v: [Double], to maxCount: Int) -> [Double] {
        let n = max(maxCount, 2)
        guard v.count > n else { return v }
        let stride = Double(v.count) / Double(n)
        return (0..<n).map { v[min(v.count - 1, Int(Double($0) * stride))] }
    }

    private var domain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        var lo = values.min() ?? 0
        var hi = values.max() ?? 1
        if let b = band { lo = min(lo, b.lowerBound); hi = max(hi, b.upperBound) }
        if hi - lo < max(minSpan, 0.0001) {
            let mid = (hi + lo) / 2
            let half = max(minSpan, 2) / 2
            lo = mid - half; hi = mid + half
        }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }
}

struct PIDPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Що показувати").font(Theme.headline)
                Spacer()
                Button("За замовчуванням") { model.selectedPIDs = PIDTable.defaultSelection }
                    .buttonStyle(.link).font(Theme.caption)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(PIDCategory.allCases, id: \.self) { cat in
                        let items = PIDTable.all.filter { $0.category == cat }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(cat.rawValue.uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.textTertiary)
                                ForEach(items) { def in
                                    Toggle(isOn: binding(def.pid)) {
                                        HStack {
                                            Text(def.name).font(Theme.body)
                                                .foregroundStyle(model.isSupported(def.pid) ? Theme.textPrimary : Theme.textTertiary)
                                            if !model.isSupported(def.pid) {
                                                Text("не підтримується").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                            }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .disabled(!model.isSupported(def.pid))
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 400, height: 480)
    }

    private func binding(_ pid: UInt8) -> Binding<Bool> {
        Binding(
            get: { model.selectedPIDs.contains(pid) },
            set: { on in
                if on { if !model.selectedPIDs.contains(pid) { model.selectedPIDs.append(pid) } }
                else { model.selectedPIDs.removeAll { $0 == pid } }
            }
        )
    }
}
#endif
