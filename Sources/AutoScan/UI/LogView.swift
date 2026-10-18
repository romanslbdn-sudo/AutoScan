#if os(macOS)
import SwiftUI
import AppKit
import AutoScanCore

/// Журнал обміну з адаптером — допомагає зрозуміти, чому немає зв'язку.
struct LogView: View {
    @EnvironmentObject var model: AppModel
    @State private var autoscroll = true

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(title: "Журнал адаптера", subtitle: "Усі команди до адаптера і його відповіді") {
                HStack(spacing: 8) {
                    Toggle("Автопрокрутка", isOn: $autoscroll).toggleStyle(.checkbox)
                    Button { copyAll() } label: { Label("Скопіювати все", systemImage: "doc.on.doc") }
                        .buttonStyle(SubtleButtonStyle())
                }
            }
            .padding([.horizontal, .top], 28)

            if model.log.isEmpty {
                EmptyStateView(icon: "list.bullet.rectangle", title: "Журнал порожній",
                               message: "Тут з'являться команди після підключення. Якщо адаптер не підключається — скопіюйте журнал і надішліть, щоб розібратися.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.log) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(Self.timeFormat.string(from: line.time))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(symbol(line.direction))
                                        .foregroundStyle(color(line.direction))
                                        .frame(width: 14)
                                    Text(line.text)
                                        .foregroundStyle(line.direction == .error ? Theme.danger : Theme.textPrimary)
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .id(line.id)
                            }
                        }
                        .padding(16)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    .padding([.horizontal, .bottom], 28)
                    .onChange(of: model.log.count) { _ in
                        if autoscroll, let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func symbol(_ d: AdapterLogLine.Direction) -> String {
        switch d {
        case .sent: return "→"
        case .received: return "←"
        case .info: return "•"
        case .error: return "!"
        }
    }

    private func color(_ d: AdapterLogLine.Direction) -> Color {
        switch d {
        case .sent: return Theme.accent
        case .received: return Theme.ok
        case .info: return Theme.info
        case .error: return Theme.danger
        }
    }

    private func copyAll() {
        let text = model.log.map { "\(Self.timeFormat.string(from: $0.time)) \(symbol($0.direction)) \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
