import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("一般", systemImage: "gearshape") { GeneralSettings() }
            Tab("データ", systemImage: "externaldrive") { DataSettings() }
            Tab("プライバシー", systemImage: "hand.raised") { PrivacySettings() }
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
            Section {
                TextField("IPv4 の宛先", text: $inet4)
                TextField("IPv6 の宛先", text: $inet6)
                Button("適用") { model.monitor.applyTargets() }
            } header: {
                Text("インターネット側の ping 宛先")
            } footer: {
                Text("ルーター宛ては自動で決まります。宛先を変えると、それまでの記録とは比較しにくくなります。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("メニューバーに表示", isOn: $showMenuBarExtra)
            } footer: {
                Text("ウインドウを閉じても、アプリが起動している間は常時計測が続きます。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @AppStorage(DataStore.folderKey) private var folderPath = ""
    @State private var picking = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                LabeledContent("保存先") {
                    Text(DataStore.folder.path(percentEncoded: false))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("変更…") { picking = true }
                    Button("既定に戻す") { folderPath = "" }.disabled(folderPath.isEmpty)
                    Spacer()
                    Button("Finder で開く") {
                        try? FileManager.default.createDirectory(at: DataStore.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(DataStore.folder)
                    }
                }
            } header: {
                Text("記録の保存先")
            } footer: {
                Text("形式は Wi-Fi Pulse 診断キットと同じ JSON Lines です。キットの data フォルダを指定すれば、tools/report.py でもそのまま集計できます。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("計測記録を削除…", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("1分ごとの集計・速度測定・負荷試験・機器一覧を削除します。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folderPath = url.path(percentEncoded: false) }
        }
        .confirmationDialog("計測記録を削除しますか？", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { DataStore.deleteRecords() }
        } message: {
            Text("この操作は取り消せません。")
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("権限") {
                LabeledContent("位置情報") {
                    HStack {
                        Text(model.location.statusText).foregroundStyle(.secondary)
                        if !model.location.isAuthorized {
                            Button("許可する…") { model.location.request() }
                        }
                    }
                }
                Button("システム設定の「位置情報サービス」を開く") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
                Button("システム設定の「ローカルネットワーク」を開く") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
            }
            Section("取得するもの") {
                Text("""
                    ・Wi-Fi の電波情報（CoreWLAN）・ルーターとインターネットへの ping・DNS 応答時間
                    ・LAN 上の機器の IP / MAC / mDNS 名（メーカー名は同梱の表で照合し、外部には送りません）
                    ・macOS の統合ログのうち Wi-Fi 関連の行（読み込んだときだけ）
                    ・速度測定と負荷試験は、それぞれ Apple と Cloudflare のサーバーと通信します
                    ルーターや Mac の設定は一切変更しません。
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
