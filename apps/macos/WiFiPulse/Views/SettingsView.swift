import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Data", systemImage: "externaldrive") { DataSettings() }
            Tab("Privacy", systemImage: "hand.raised") { PrivacySettings() }
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

private struct DataSettings: View {
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
            Button("Delete", role: .destructive) { DataStore.deleteRecords() }
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
