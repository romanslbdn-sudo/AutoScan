#if os(macOS)
import SwiftUI
import AutoScanCore

struct FaultsView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: DTCKind? = nil
    @State private var confirmClear = false
    @State private var expanded: Set<String> = []

    private var filtered: [DTC] {
        guard let f = filter else { return model.dtcs }
        return model.dtcs.filter { $0.kind == f }
    }

    var body: some View {
        if !model.connection.isConnected {
            NotConnectedView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Помилки", subtitle: subtitle) {
                        HStack(spacing: 8) {
                            Button {
                                Task { await model.readDTCs() }
                            } label: {
                                Label(model.isReadingDTCs ? "Читаю…" : "Прочитати ще раз", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(SubtleButtonStyle())
                            .disabled(model.isReadingDTCs)

                            Button {
                                confirmClear = true
                            } label: {
                                Label(model.isClearing ? "Стираю…" : "Стерти помилки", systemImage: "trash")
                            }
                            .buttonStyle(SubtleButtonStyle(color: Theme.danger))
                            .disabled(model.isClearing || model.dtcs.isEmpty)
                        }
                    }

                    filterBar

                    if model.isReadingDTCs && model.dtcs.isEmpty {
                        HStack { ProgressView(); Text("Читаю помилки з блока…").foregroundStyle(Theme.textSecondary) }
                            .frame(maxWidth: .infinity).padding(40)
                    } else if model.dtcs.isEmpty {
                        Card {
                            HStack(spacing: 16) {
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 38)).foregroundStyle(Theme.ok)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Помилок не знайдено").font(Theme.title).foregroundStyle(Theme.textPrimary)
                                    Text("Блок керування двигуном не зберігає жодного коду несправності. Якщо щось турбує — подивіться «Живі дані».")
                                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    } else {
                        ForEach(filtered) { dtc in
                            DTCCard(dtc: dtc, isExpanded: expanded.contains(dtc.id)) {
                                if expanded.contains(dtc.id) { expanded.remove(dtc.id) } else { expanded.insert(dtc.id) }
                            }
                        }
                    }

                    Text("Опитується блок керування двигуном (OBD2). Помилки ABS, подушок, коробки та інших блоків загальний протокол OBD2 зазвичай не показує.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(28)
            }
            .confirmationDialog("Стерти всі помилки?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Стерти", role: .destructive) { Task { await model.clearDTCs() } }
                Button("Скасувати", role: .cancel) {}
            } message: {
                Text("Запалювання має бути увімкнене, двигун — заглушений. Разом з помилками зітруться дані «стоп-кадру» і скинуться монітори готовності (авто може не пройти техогляд, поки не проїде кілька поїздок). Якщо причину не усунуто — помилка повернеться.")
            }
            .onAppear {
                if expanded.isEmpty, let first = model.dtcs.first { expanded.insert(first.id) }
            }
        }
    }

    private var subtitle: String {
        if model.dtcs.isEmpty { return "Коди несправностей з блока двигуна" }
        return "Знайдено кодів: \(model.uniqueCodes.count). Натисніть на помилку, щоб побачити причини."
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            filterChip(nil, "Усі", model.dtcs.count)
            ForEach(DTCKind.allCases, id: \.self) { k in
                filterChip(k, k.title, model.dtcs.filter { $0.kind == k }.count)
            }
            Spacer()
        }
    }

    private func filterChip(_ k: DTCKind?, _ title: String, _ n: Int) -> some View {
        let on = filter == k
        return Button { filter = k } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .background(Capsule().fill(on ? Theme.cardRaised : Theme.card))
            .overlay(Capsule().stroke(on ? Theme.accent.opacity(0.7) : Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

struct DTCCard: View {
    @EnvironmentObject var model: AppModel
    let dtc: DTC
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let info = model.entry(for: dtc)
        let e = info.entry
        let sevColor = Theme.severityColor(e.severity)
        let hasChecks = !NormRules.checks(for: dtc.code).isEmpty

        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(sevColor).frame(width: 4)
            VStack(alignment: .leading, spacing: 12) {
                Button(action: toggle) {
                    HStack(alignment: .center, spacing: 14) {
                        Text(dtc.code).font(Theme.code).foregroundStyle(Theme.textPrimary)
                            .frame(width: 86, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Pill(text: dtc.kind.title, color: Theme.kindColor(dtc.kind))
                                Pill(text: dtc.systemTitle, color: Theme.textSecondary)
                                if dtc.isManufacturerSpecific { Pill(text: "заводський код", color: Theme.info) }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(e.details).font(Theme.body).foregroundStyle(Theme.textPrimary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Image(systemName: e.severity >= 3 ? "exclamationmark.octagon.fill" : "info.circle.fill")
                                .foregroundStyle(sevColor)
                            Text(e.severityTitle).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(sevColor)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Найчастіші причини (від найімовірнішої)").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            ForEach(Array(e.causes.enumerated()), id: \.offset) { i, cause in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Theme.cardRaised))
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(cause).font(Theme.body).foregroundStyle(Theme.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        Text(dtc.kind.explanation).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("Джерело: \(info.source)").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            Spacer()
                            if hasChecks {
                                Button {
                                    model.screen = .norm
                                } label: {
                                    Label("Норма vs зараз", systemImage: "chart.line.uptrend.xyaxis")
                                }
                                .buttonStyle(AccentButtonStyle())
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(16)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }
}
#endif
