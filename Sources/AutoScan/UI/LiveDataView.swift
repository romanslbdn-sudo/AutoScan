#if os(macOS)
import SwiftUI
import Charts
import AutoScanCore

struct LiveDataView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPicker = false

    var body: some View {
        if !model.connection.isConnected {
            NotConnectedView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Живі дані", subtitle: "Показники датчиків у реальному часі") {
                        HStack(spacing: 8) {
                            Button {
                                model.livePaused.toggle()
                            } label: {
                                Label(model.livePaused ? "Продовжити" : "Пауза", systemImage: model.livePaused ? "play.fill" : "pause.fill")
                            }
                            .buttonStyle(SubtleButtonStyle())
                            Button { model.resetHistory() } label: { Label("Очистити графіки", systemImage: "eraser") }
                                .buttonStyle(SubtleButtonStyle())
                            Button { showPicker = true } label: { Label("Параметри", systemImage: "slider.horizontal.3") }
                                .buttonStyle(AccentButtonStyle())
                                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                                    PIDPicker().environmentObject(model)
                                }
                        }
                    }

                    if model.selectedPIDs.isEmpty {
                        EmptyStateView(icon: "slider.horizontal.3", title: "Параметри не вибрано",
                                       message: "Натисніть «Параметри» і виберіть, які показники дивитися.",
                                       actionTitle: "Вибрати параметри") { showPicker = true }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
                            ForEach(model.selectedPIDs, id: \.self) { pid in
                                if let def = PIDTable.definition(pid) {
                                    PIDTile(def: def, supported: model.isSupported(pid))
                                }
                            }
                        }
                    }

                    Text("Чим більше параметрів вибрано, тим рідше оновлюється кожен — адаптер опитує їх по черзі.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(28)
            }
        }
    }
}

struct PIDTile: View {
    @EnvironmentObject var model: AppModel
    let def: PIDDefinition
    let supported: Bool

    var body: some View {
        let value = model.values[def.pid]
        let hist = model.history[def.pid] ?? []
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(def.shortName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(def.category.rawValue).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(supported ? (value.map { def.format($0) } ?? "…") : "—")
                        .font(Theme.number(30)).foregroundStyle(Theme.textPrimary)
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
                    Sparkline(values: hist, color: Theme.accent)
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
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent
    var band: ClosedRange<Double>? = nil
    var yDomain: ClosedRange<Double>? = nil

    var body: some View {
        let pts = Array(values.enumerated())
        Chart {
            if let band {
                RectangleMark(xStart: .value("x", 0), xEnd: .value("x", max(values.count - 1, 1)),
                              yStart: .value("lo", band.lowerBound), yEnd: .value("hi", band.upperBound))
                    .foregroundStyle(Theme.ok.opacity(0.12))
            }
            ForEach(pts, id: \.offset) { i, v in
                AreaMark(x: .value("t", i), y: .value("v", v))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", i), y: .value("v", v))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
    }

    private var domain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        var lo = values.min() ?? 0
        var hi = values.max() ?? 1
        if let b = band { lo = min(lo, b.lowerBound); hi = max(hi, b.upperBound) }
        if hi - lo < 0.0001 { lo -= 1; hi += 1 }
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
