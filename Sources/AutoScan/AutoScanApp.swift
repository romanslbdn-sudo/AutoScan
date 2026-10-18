#if os(macOS)
import SwiftUI
import AppKit
import AutoScanCore

@main
struct AutoScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // Службовий режим для перевірки: AutoScan --sample-pdf <шлях> створює зразок акту і виходить.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--sample-pdf"), i + 1 < args.count {
            let data = ReportPDF.make(job: .sample, profile: .sample)
            try? data.write(to: URL(fileURLWithPath: args[i + 1]))
            exit(data.isEmpty ? 1 : 0)
        }
    }

    var body: some Scene {
        WindowGroup("AutoScan") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.logStore)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Вигляд") {
                Button("Перемкнути нічний режим") {
                    let d = UserDefaults.standard
                    let night = d.string(forKey: "theme.mode") == ThemeMode.night.rawValue
                    d.set(night ? ThemeMode.dark.rawValue : ThemeMode.night.rawValue, forKey: "theme.mode")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Діагностика") {
                Button("Підключитися…") { model.showConnectSheet = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Прочитати помилки") { Task { await model.readDTCs() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.connection.isConnected)
                Divider()
                Button("Відключитися") { model.disconnect() }
                    .disabled(!model.connection.isConnected)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("theme.mode") private var themeMode = ThemeMode.dark.rawValue

    var body: some View {
        // Тема застосовується до перемальовування, тож усі кольори беруться вже нові
        let _ = (Theme.mode = ThemeMode(rawValue: themeMode) ?? .dark)
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            ZStack {
                Theme.background.ignoresSafeArea()
                detail
            }
        }
        // Повна перебудова вікна при зміні теми — щоб усі кольори оновились одразу
        .id(themeMode)
        .sheet(isPresented: $model.showConnectSheet) {
            ConnectSheet()
                .environmentObject(model)
                .environmentObject(model.live)
        }
        .alert("AutoScan", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("Гаразд", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.screen {
        case .overview: OverviewView()
        case .faults: FaultsView()
        case .live: LiveDataView()
        case .norm: NormView()
        case .report: ClientReportView()
        case .retro: RetroView()
        case .packs: PacksView()
        case .log: LogView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent, Theme.info], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 34, height: 34)
                    Image(systemName: "gauge.medium").font(.system(size: 17, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("AutoScan").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("діагностика OBD2").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 22)

            VStack(spacing: 3) {
                ForEach([Screen.overview, .faults, .live, .norm, .report, .retro, .packs]) { s in
                    SidebarItem(screen: s, badge: badge(for: s))
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            ThemeToggle()
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            SidebarItem(screen: .log, badge: nil)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ConnectionBadge()
                .padding(12)
        }
        .background(Theme.sidebar.ignoresSafeArea())
    }

    private func badge(for s: Screen) -> Int? {
        if s == .faults, !model.dtcs.isEmpty { return model.uniqueCodes.count }
        return nil
    }
}

/// Перемикач «Темний / Нічний».
struct ThemeToggle: View {
    @AppStorage("theme.mode") private var themeMode = ThemeMode.dark.rawValue

    var body: some View {
        let night = themeMode == ThemeMode.night.rawValue
        Button {
            themeMode = night ? ThemeMode.dark.rawValue : ThemeMode.night.rawValue
        } label: {
            HStack(spacing: 10) {
                Image(systemName: night ? "moon.fill" : "moon")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(night ? "Нічний режим" : "Темний режим").font(.system(size: 13.5))
                Spacer()
                Text(night ? "увімк." : "вимк.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Нічний режим: ще темніший фон і приглушені кольори, щоб не втомлювались очі")
    }
}

struct SidebarItem: View {
    @EnvironmentObject var model: AppModel
    let screen: Screen
    let badge: Int?

    var body: some View {
        let selected = model.screen == screen
        Button {
            model.screen = screen
        } label: {
            HStack(spacing: 10) {
                Image(systemName: screen.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(screen.title).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer()
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.danger))
                        .foregroundStyle(.white)
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.cardRaised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.showConnectSheet = true
        } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch model.connection {
        case .connected: return Theme.ok
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .disconnected: return Theme.textTertiary
        }
    }

    private var title: String {
        switch model.connection {
        case .connected: return model.isDemo ? "Демо-режим" : "Підключено"
        case .connecting: return "Підключення…"
        case .failed: return "Немає зв'язку"
        case .disconnected: return "Не підключено"
        }
    }

    private var subtitle: String {
        switch model.connection {
        case .connected: return model.adapterName
        case .connecting(let s): return s
        case .failed: return "Натисніть, щоб спробувати ще"
        case .disconnected: return "Натисніть, щоб підключитися"
        }
    }
}
#endif
