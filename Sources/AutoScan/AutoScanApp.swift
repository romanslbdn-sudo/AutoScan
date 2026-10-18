#if os(macOS)
import SwiftUI
import AppKit
import AutoScanCore

@main
struct AutoScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

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

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            ZStack {
                Theme.background.ignoresSafeArea()
                detail
            }
        }
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
                ForEach([Screen.overview, .faults, .live, .norm, .packs]) { s in
                    SidebarItem(screen: s, badge: badge(for: s))
                }
            }
            .padding(.horizontal, 10)

            Spacer()

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
