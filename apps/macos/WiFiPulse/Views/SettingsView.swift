import SwiftUI

/// 設定の画面のタブ。ほかの画面から特定のタブを開くときは `select` してから開く
enum SettingsTab: String {
    case general, networks, data, privacy

    static let key = "settingsTab"

    static func select(_ tab: SettingsTab) { UserDefaults.standard.set(tab.rawValue, forKey: key) }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Networks", systemImage: "wifi.router", value: .networks) { NetworkSettings() }
            Tab("Data", systemImage: "externaldrive", value: .data) { DataSettings() }
            Tab("Privacy", systemImage: "hand.raised", value: .privacy) { PrivacySettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("inet4Target") private var inet4 = "1.1.1.1"
    @AppStorage("inet6Target") private var inet6 = "2001:4860:4860::8888"
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some View {
        Form {
            LanguageSection()
            AppearanceSection()
            Section {
                TextField("IPv4 target", text: $inet4)
                TextField("IPv6 target", text: $inet6)
                Button("Apply") { model.monitor.applyTargets() }
            } header: {
                Text("Internet Ping Targets")
            } footer: {
                Text("The router target is detected automatically. Changing targets makes comparison with earlier records harder.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show in Menu Bar", isOn: $showMenuBarExtra)
            } footer: {
                Text("Monitoring continues while the app is running, even with the window closed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 表示言語。既定はシステム設定に従う。変更は再起動で反映される。
private struct LanguageSection: View {
    /// 空文字列 = システム設定に従う
    @State private var choice = AppLanguage.override ?? ""

    var body: some View {
        // 再起動が要るかは「いま選んでいる値」から判定する。
        // 保存済みの値（UserDefaults）を見ると、onChange より先に描画されたときに1つ前の選択で判定してしまう
        let needsRestart = AppLanguage.launchLanguage(choice: choice) != AppLanguage.current
        Section {
            Picker("Language", selection: Binding(
                get: { choice },
                set: { newValue in
                    choice = newValue
                    AppLanguage.override = newValue.isEmpty ? nil : newValue
                }
            )) {
                Text("System Setting (\(AppLanguage.displayName(AppLanguage.systemChoice)))").tag("")
                Divider()
                ForEach(AppLanguage.available, id: \.self) { code in
                    Text(verbatim: AppLanguage.displayName(code)).tag(code)
                }
            }
            if needsRestart {
                HStack {
                    Label("Restart Wi-Fi Pulse to apply the change.", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") { AppLanguage.relaunch() }
                }
            }
        } footer: {
            Text("You can also change this in System Settings › General › Language & Region › Applications.")
                .foregroundStyle(.secondary)
        }
    }
}

/// 外観。既定はシステム設定に従う。すぐに反映される。
private struct AppearanceSection: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system

    var body: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: appearance) { _, newValue in AppAppearance.apply(newValue) }
        }
    }
}

/// 計測したネットワークの名前の変更と統合
private struct NetworkSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.monitor
        let list = monitor.networks.representatives
        Form {
            if list.isEmpty {
                ContentUnavailableView("No Networks Yet", systemImage: "wifi.router",
                                       description: Text("Networks appear here once the app has measured them."))
            }
            ForEach(list) { n in
                Section {
                    NetworkNameField(network: n)
                    LabeledContent("Router", value: routerText(n))
                    LabeledContent("First Recorded") {
                        Text(Date(epochMs: n.first), format: .dateTime.year().month().day().hour().minute())
                    }
                    ForEach(monitor.networks.members(of: n.id)) { m in
                        LabeledContent {
                            Button("Separate") { monitor.separateNetwork(m.id) }
                        } label: {
                            Text("Includes records of \(m.automaticName)")
                            Text(routerText(m))
                        }
                    }
                    let targets = list.filter { $0.id != n.id }
                    if !targets.isEmpty {
                        Menu("Merge Into") {
                            ForEach(targets) { t in
                                Button(t.displayName) { monitor.mergeNetwork(n.id, into: t.id) }
                            }
                        }
                        .fixedSize()
                    }
                } header: {
                    HStack {
                        Text(n.displayName)
                        if n.id == monitor.currentNetwork {
                            Text("This Network").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("Records are kept for each router. If the same network was recorded twice (for example, before and after the router’s address could be read), merge one into the other. Merging doesn’t change the record files and can be undone with Separate.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func routerText(_ n: KnownNetwork) -> String {
        n.isGatewayOnly ? String(localized: "\(n.gateway) (router address unknown)") : "\(n.gateway) · \(n.id)"
    }
}

/// 名前の欄。1文字ごとに保存しないよう、確定したとき（Return・フォーカスが外れたとき）に保存する
private struct NetworkNameField: View {
    @Environment(AppModel.self) private var model
    let network: KnownNetwork
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text, prompt: Text(network.automaticName))
            .focused($focused)
            .onAppear { text = network.name ?? "" }
            .onChange(of: network.name) { _, new in if !focused { text = new ?? "" } }
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() { model.monitor.renameNetwork(network.id, to: text) }
}

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DataStore.folderKey) private var folderPath = ""
    @State private var picking = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    Text(DataStore.folder.path(percentEncoded: false))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change…") { picking = true }
                    Button("Restore Default") { folderPath = "" }.disabled(folderPath.isEmpty)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: DataStore.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(DataStore.folder)
                    }
                }
            } header: {
                Text("Record Location")
            } footer: {
                Text("Records are stored as JSON Lines, the same format as the Wi-Fi Pulse diagnostic kit. Point this at the kit’s data folder to analyze them with tools/report.py as well.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Delete Records…", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Deletes per-minute records, speed tests, load tests, and the device list.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folderPath = url.path(percentEncoded: false) }
        }
        .confirmationDialog("Delete all measurement records?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                DataStore.deleteRecords()
                model.monitor.recordsDeleted()
            }
        } message: {
            Text("This can’t be undone.")
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Location") {
                    HStack {
                        Text(model.location.statusText).foregroundStyle(.secondary)
                        if !model.location.isAuthorized {
                            Button("Allow…") { model.location.request() }
                        }
                    }
                }
                Button("Open Location Services Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
                Button("Open Local Network Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
            }
            Section("What Is Collected") {
                Text("""
                    • Wi-Fi radio information (CoreWLAN), pings to the router and the Internet, and DNS response times
                    • IP, MAC, and mDNS names of devices on your local network (manufacturers are looked up in a bundled table and never sent anywhere)
                    • Wi-Fi–related lines from the macOS unified log (only when you load them)
                    • Speed tests and load tests communicate with Apple and Cloudflare servers, respectively
                    Router and Mac settings are never changed.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
