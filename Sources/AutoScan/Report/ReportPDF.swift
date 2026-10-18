#if os(macOS)
import SwiftUI
import AppKit

/// Створює PDF-акт для клієнта (формат A4, світле оформлення для друку).
///
/// Акт складається з окремих блоків (шапка, авто, кожна помилка, кожен пункт робіт…).
/// Кожен блок вимірюється й розкладається по сторінках, тож довгі списки
/// акуратно переносяться на наступну сторінку.
@MainActor
enum ReportPDF {
    static let pageSize = CGSize(width: 595.2, height: 841.8)   // A4 у пунктах
    static let margin: CGFloat = 40
    static var contentWidth: CGFloat { pageSize.width - margin * 2 }

    // Кольори для друку
    static let ink = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let soft = Color(red: 0.38, green: 0.41, blue: 0.47)
    static let line = Color(red: 0.86, green: 0.88, blue: 0.91)
    static let panel = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let accent = Color(red: 0.05, green: 0.55, blue: 0.52)
    static let red = Color(red: 0.80, green: 0.18, blue: 0.18)
    static let amber = Color(red: 0.80, green: 0.50, blue: 0.05)
    static let green = Color(red: 0.13, green: 0.58, blue: 0.30)
    static let blue = Color(red: 0.20, green: 0.40, blue: 0.80)

    static func severityColor(_ s: Int) -> Color { s >= 3 ? red : (s == 2 ? amber : blue) }

    struct Block {
        let view: AnyView
        var spacingAfter: CGFloat = 8
        /// Почати з нової сторінки, якщо блок-заголовок опинився внизу без вмісту під ним.
        var keepWithNext = false
    }

    // MARK: Побудова

    static func make(job: ServiceJob, profile: ServiceProfile) -> Data {
        render(blocks(job: job, profile: profile))
    }

    static func blocks(job: ServiceJob, profile: ServiceProfile) -> [Block] {
        var b: [Block] = []
        b.append(Block(view: AnyView(Header(job: job, profile: profile)), spacingAfter: 16))
        b.append(Block(view: AnyView(ClientCar(job: job)), spacingAfter: 18))

        if !job.complaint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            b.append(Block(view: AnyView(SectionTitle(text: "Звернення клієнта")), spacingAfter: 6, keepWithNext: true))
            b.append(Block(view: AnyView(Paragraph(text: job.complaint)), spacingAfter: 16))
        }

        if let before = job.before {
            b += snapshotBlocks(title: "Стан ДО ремонту", snap: before, previous: nil)
        }

        let works = ServiceJob.lines(job.works)
        if !works.isEmpty {
            b.append(Block(view: AnyView(SectionTitle(text: "Виконані роботи")), spacingAfter: 6, keepWithNext: true))
            for (i, w) in works.enumerated() {
                b.append(Block(view: AnyView(ListItem(number: i + 1, text: w, icon: "wrench.and.screwdriver")), spacingAfter: 4))
            }
            b.append(Block(view: AnyView(Spacer().frame(height: 10)), spacingAfter: 0))
        }

        let parts = ServiceJob.lines(job.parts)
        if !parts.isEmpty {
            b.append(Block(view: AnyView(SectionTitle(text: "Замінені запчастини")), spacingAfter: 6, keepWithNext: true))
            for (i, p) in parts.enumerated() {
                b.append(Block(view: AnyView(ListItem(number: i + 1, text: p, icon: "gearshape")), spacingAfter: 4))
            }
            b.append(Block(view: AnyView(Spacer().frame(height: 10)), spacingAfter: 0))
        }

        if let after = job.after {
            b += snapshotBlocks(title: "Стан ПІСЛЯ ремонту", snap: after, previous: job.before)
        }

        let recs = ServiceJob.lines(job.recommendations)
        if !recs.isEmpty {
            b.append(Block(view: AnyView(SectionTitle(text: "Рекомендації")), spacingAfter: 6, keepWithNext: true))
            for r in recs {
                b.append(Block(view: AnyView(ListItem(number: nil, text: r, icon: "lightbulb")), spacingAfter: 4))
            }
            b.append(Block(view: AnyView(Spacer().frame(height: 10)), spacingAfter: 0))
        }

        b.append(Block(view: AnyView(Signatures(profile: profile)), spacingAfter: 0))
        return b
    }

    static func snapshotBlocks(title: String, snap: DiagnosticSnapshot, previous: DiagnosticSnapshot?) -> [Block] {
        var b: [Block] = []
        b.append(Block(view: AnyView(SectionTitle(text: title, date: snap.date)), spacingAfter: 8, keepWithNext: true))

        if let prev = previous {
            let fixed = prev.codeSet.subtracting(snap.codeSet).sorted()
            let left = prev.codeSet.intersection(snap.codeSet).sorted()
            let new = snap.codeSet.subtracting(prev.codeSet).sorted()
            b.append(Block(view: AnyView(Comparison(fixed: fixed, left: left, new: new)), spacingAfter: 10))
        }

        b.append(Block(view: AnyView(SnapshotSummary(snap: snap)), spacingAfter: 8))
        for c in snap.codes {
            b.append(Block(view: AnyView(CodeRow(code: c)), spacingAfter: 5))
        }
        if !snap.readings.isEmpty {
            b.append(Block(view: AnyView(Readings(readings: snap.readings)), spacingAfter: 8))
        }
        let problems = snap.checks.filter(\.problem)
        if !problems.isEmpty {
            b.append(Block(view: AnyView(ChecksTable(checks: problems)), spacingAfter: 8))
        }
        b.append(Block(view: AnyView(Spacer().frame(height: 8)), spacingAfter: 0))
        return b
    }

    // MARK: Розкладка по сторінках і малювання

    static func render(_ blocks: [Block]) -> Data {
        let width = contentWidth
        let footerSpace: CGFloat = 28
        let usable = pageSize.height - margin * 2 - footerSpace

        // Виміряти всі блоки
        var measured: [(Block, ImageRenderer<AnyView>, CGFloat)] = []
        for block in blocks {
            let r = ImageRenderer(content: AnyView(block.view.frame(width: width, alignment: .leading)
                .environment(\.colorScheme, .light)))
            r.proposedSize = ProposedViewSize(width: width, height: nil)
            var h: CGFloat = 0
            r.render { size, _ in h = size.height }
            measured.append((block, r, h))
        }

        // Розкласти по сторінках
        var pages: [[(ImageRenderer<AnyView>, CGFloat, CGFloat)]] = [[]]
        var y: CGFloat = 0
        for (i, item) in measured.enumerated() {
            let (block, r, h) = item
            var need = h
            if block.keepWithNext, i + 1 < measured.count { need += block.spacingAfter + measured[i + 1].2 }
            if y > 0 && y + need > usable {
                pages.append([])
                y = 0
            }
            pages[pages.count - 1].append((r, y, h))
            y += h + block.spacingAfter
        }

        // Намалювати
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [
                kCGPDFContextTitle as String: "Акт діагностики AutoScan",
                kCGPDFContextCreator as String: "AutoScan"
              ] as CFDictionary) else { return Data() }

        for (index, page) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            for (r, top, h) in page {
                ctx.saveGState()
                // PDF рахує від низу сторінки
                ctx.translateBy(x: margin, y: pageSize.height - margin - top - h)
                r.render { _, draw in draw(ctx) }
                ctx.restoreGState()
            }
            let footer = ImageRenderer(content: AnyView(Footer(page: index + 1, total: pages.count)
                .frame(width: width).environment(\.colorScheme, .light)))
            footer.proposedSize = ProposedViewSize(width: width, height: nil)
            ctx.saveGState()
            ctx.translateBy(x: margin, y: margin - 8)
            footer.render { _, draw in draw(ctx) }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: Блоки акту

    struct Header: View {
        let job: ServiceJob
        let profile: ServiceProfile
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name.isEmpty ? "Автосервіс" : profile.name)
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(ink)
                        let contacts = [profile.address, profile.phone].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !contacts.isEmpty {
                            Text(contacts).font(.system(size: 9.5)).foregroundStyle(soft)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(accent)
                        Text(Date().formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "uk_UA"))))
                            .font(.system(size: 9.5)).foregroundStyle(soft)
                    }
                }
                Rectangle().fill(accent).frame(height: 2)
            }
        }
        var title: String {
            switch (job.before != nil, job.after != nil || !job.works.isEmpty) {
            case (_, true): return "Акт діагностики та ремонту"
            default: return "Акт діагностики"
            }
        }
    }

    struct ClientCar: View {
        let job: ServiceJob
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                box("Клієнт", [("Ім'я", job.clientName), ("Телефон", job.clientPhone)])
                box("Автомобіль", [("Авто", job.carTitle), ("Держномер", job.plate), ("VIN", job.vin), ("Пробіг", job.mileage.isEmpty ? "" : job.mileage + " км")])
            }
        }
        func box(_ title: String, _ rows: [(String, String)]) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(soft).kerning(0.6)
                ForEach(rows.filter { !$0.1.isEmpty }, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.0).font(.system(size: 9.5)).foregroundStyle(soft).frame(width: 62, alignment: .leading)
                        Text(row.1).font(.system(size: 10.5, weight: .medium)).foregroundStyle(ink)
                    }
                }
                if rows.allSatisfy({ $0.1.isEmpty }) {
                    Text("—").font(.system(size: 10.5)).foregroundStyle(soft)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(panel))
        }
    }

    struct SectionTitle: View {
        let text: String
        var date: Date? = nil
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text).font(.system(size: 13, weight: .bold)).foregroundStyle(ink)
                    Spacer()
                    if let date {
                        Text(date.formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "uk_UA"))))
                            .font(.system(size: 9)).foregroundStyle(soft)
                    }
                }
                Rectangle().fill(line).frame(height: 1)
            }
        }
    }

    struct Paragraph: View {
        let text: String
        var body: some View {
            Text(text).font(.system(size: 10.5)).foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    struct ListItem: View {
        let number: Int?
        let text: String
        let icon: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let number {
                    Text("\(number).").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(accent)
                        .frame(width: 18, alignment: .trailing)
                } else {
                    Image(systemName: icon).font(.system(size: 9)).foregroundStyle(accent).frame(width: 18)
                }
                Text(text).font(.system(size: 10.5)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    struct SnapshotSummary: View {
        let snap: DiagnosticSnapshot
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: snap.codes.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(snap.codes.isEmpty ? green : amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snap.codes.isEmpty ? "Помилок у блоці керування не виявлено" : "Виявлено помилок: \(Set(snap.codes.map(\.code)).count)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
                    if let mil = snap.milOn {
                        Text(mil ? "Лампа Check Engine горить" : "Лампа Check Engine не горить")
                            .font(.system(size: 9.5)).foregroundStyle(soft)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(snap.codes.isEmpty ? green.opacity(0.08) : amber.opacity(0.08)))
        }
    }

    struct CodeRow: View {
        let code: DiagnosticSnapshot.Code
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(severityColor(code.severity)).frame(width: 3, height: 12)
                Text(code.code).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(ink)
                    .frame(width: 46, alignment: .leading)
                Text(code.title).font(.system(size: 10.5)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(code.kind).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(soft)
            }
        }
    }

    struct Comparison: View {
        let fixed: [String]
        let left: [String]
        let new: [String]
        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                col("Усунено", fixed, green, "checkmark.circle.fill")
                col("Залишилось", left, amber, "exclamationmark.circle.fill")
                col("Нові", new, red, "plus.circle.fill")
            }
        }
        func col(_ title: String, _ codes: [String], _ color: Color, _ icon: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon).font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
                Text(codes.isEmpty ? "—" : codes.joined(separator: ", "))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.08)))
        }
    }

    struct Readings: View {
        let readings: [DiagnosticSnapshot.Reading]
        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("ПОКАЗНИКИ ДАТЧИКІВ").font(.system(size: 8, weight: .bold)).foregroundStyle(soft).kerning(0.6)
                // Звичайні рядки замість LazyVGrid: «ліниві» контейнери не малюються при експорті в PDF
                let rows = stride(from: 0, to: readings.count, by: 2).map { Array(readings[$0..<min($0 + 2, readings.count)]) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 16) {
                        ForEach(pair, id: \.label) { r in
                            HStack(spacing: 4) {
                                Text(r.label).font(.system(size: 9)).foregroundStyle(soft).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(r.value).font(.system(size: 9.5, weight: .semibold).monospacedDigit()).foregroundStyle(ink)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        if pair.count == 1 { Spacer().frame(maxWidth: .infinity) }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(panel))
        }
    }

    struct ChecksTable: View {
        let checks: [DiagnosticSnapshot.Check]
        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("ВІДХИЛЕННЯ ВІД НОРМИ").font(.system(size: 8, weight: .bold)).foregroundStyle(soft).kerning(0.6)
                ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(c.code).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(soft)
                            .frame(width: 40, alignment: .leading)
                        Text(c.title).font(.system(size: 9.5)).foregroundStyle(ink)
                        Spacer(minLength: 6)
                        Text(c.actual).font(.system(size: 9.5, weight: .semibold).monospacedDigit()).foregroundStyle(ink)
                        Text(c.verdict).font(.system(size: 8.5, weight: .bold)).foregroundStyle(amber)
                            .lineLimit(1)
                            .frame(width: 118, alignment: .trailing)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).stroke(line))
        }
    }

    struct Signatures: View {
        let profile: ServiceProfile
        var body: some View {
            HStack(alignment: .bottom, spacing: 30) {
                sign("Майстер", profile.master)
                sign("Клієнт", "")
            }
            .padding(.top, 18)
        }
        func sign(_ role: String, _ name: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(soft).frame(height: 0.7).padding(.top, 22)
                Text(name.isEmpty ? role : "\(role): \(name)").font(.system(size: 9)).foregroundStyle(soft)
            }
            .frame(maxWidth: .infinity)
        }
    }

    struct Footer: View {
        let page: Int
        let total: Int
        var body: some View {
            HStack {
                Text("Діагностика виконана за допомогою AutoScan (OBD2)").font(.system(size: 7.5)).foregroundStyle(soft)
                Spacer()
                Text("Сторінка \(page) з \(total)").font(.system(size: 7.5)).foregroundStyle(soft)
            }
        }
    }
}
#endif
