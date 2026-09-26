import SwiftUI

@main
struct WiFiPulseApp: App {
    @State private var model = AppModel()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        Window("Wi-Fi Pulse", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1200, height: 800)
        .commands { AppCommands(model: model) }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// アプリ全体で共有する計測器。ウインドウを閉じても常時計測は止まらない。
@Observable
final class AppModel {
    let monitor = Monitor()
    let speedTest = SpeedTest()
    let loadTest = LoadTest()
    let events = WiFiEvents()
    let neighbors = NeighborScanner()
    let processes = ProcessMonitor()
    let location = LocationAccess()

    var selection: SidebarItem? {
        didSet { UserDefaults.standard.set(selection?.rawValue, forKey: "selectedView") }
    }

    init() {
        selection = UserDefaults.standard.string(forKey: "selectedView").flatMap(SidebarItem.init(rawValue:)) ?? .overview
        monitor.start()
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("計測") {
            Button("速度を測る") {
                Task { await model.speedTest.run(interface: model.monitor.env.interface) }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model.speedTest.isRunning)

            Button("周辺のWi-Fiをスキャン") {
                model.selection = .neighbors
                Task { await model.neighbors.scan() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("LANの機器を探す") {
                model.monitor.devices.requestSweep()
            }

            Divider()

            Button("データフォルダを開く") {
                try? FileManager.default.createDirectory(at: DataStore.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(DataStore.folder)
            }
        }
        CommandGroup(after: .sidebar) {
            ForEach(SidebarItem.allCases) { item in
                if let key = item.shortcut {
                    Button(item.title) { model.selection = item }
                        .keyboardShortcut(key, modifiers: .command)
                } else {
                    Button(item.title) { model.selection = item }
                }
            }
        }
    }
}
