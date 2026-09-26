import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Device.ID?
    @State private var search = ""
    @State private var showOffline = false
    @State private var showInspector = true

    var body: some View {
        let scanner = model.monitor.devices
        let all = scanner.devices
        let list = all.filter { d in
            (showOffline || d.online == true)
                && (search.isEmpty || [d.displayName, d.ip ?? "", d.mac, d.vendor ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }

        Group {
            if all.isEmpty {
                ContentUnavailableView {
                    Label(scanner.isSweeping ? "機器を探しています…" : "機器が見つかりません", systemImage: "network")
                } description: {
                    Text(scanner.arpWorks
                         ? "LAN 内のアドレスに1回ずつ問い合わせて、応答した機器を一覧にします。"
                         : "ローカルネットワークへのアクセスが許可されていない可能性があります。システム設定 › プライバシーとセキュリティ › ローカルネットワーク を確認してください。")
                } actions: {
                    Button("探す") { scanner.requestSweep() }
                        .buttonStyle(.glassProminent)
                        .disabled(scanner.isSweeping)
                }
            } else {
                Table(list, selection: $selection) {
                    TableColumn("") { d in
                        Image(systemName: d.symbol)
                            .foregroundStyle(d.online == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            .accessibilityLabel(d.kindLabel)
                    }
                    .width(24)
                    TableColumn("名前") { d in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.displayName).fontWeight(d.name != nil ? .semibold : .regular)
                            if d.ip == model.monitor.env.gateway {
                                Text("このネットワークのルーター").font(.caption).foregroundStyle(.secondary)
                            } else if d.ip == model.monitor.env.selfIP {
                                Text("このMac").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("IPアドレス") { Text($0.ip ?? "—").monospacedDigit() }
                        .width(min: 100, ideal: 120)
                    TableColumn("メーカー") { d in
                        Text(d.vendor_ja ?? d.vendor ?? (d.random == true ? "プライベートアドレス" : "不明"))
                            .foregroundStyle(d.vendor == nil ? .secondary : .primary)
                    }
                    TableColumn("種類") { Text($0.kindLabel) }
                        .width(min: 70, ideal: 90)
                    TableColumn("状態") { d in
                        if d.online == true {
                            Label("オンライン", systemImage: "circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon).imageScale(.small)
                        } else {
                            Text(d.lastSeen, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 90, ideal: 110)
                }
                .contextMenu(forSelectionType: Device.ID.self) { ids in
                    if let mac = ids.first {
                        Button("MACアドレスをコピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(mac, forType: .string)
                        }
                    }
                }
            }
        }
        .navigationTitle("機器")
        .searchable(text: $search, placement: .toolbar, prompt: "名前・IP・メーカー")
        .inspector(isPresented: $showInspector) {
            DeviceInspector(device: all.first { $0.id == selection })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $showOffline) {
                    Label("オフラインも表示", systemImage: "clock.arrow.circlepath")
                }
                .help("過去に見つかった機器も表示します")
                Button {
                    scanner.requestSweep()
                } label: {
                    Label("探す", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isSweeping)
                .help("LAN内の全アドレスに問い合わせて一覧を更新します")
                Button {
                    showInspector.toggle()
                } label: {
                    Label("インスペクタ", systemImage: "sidebar.trailing")
                }
            }
        }
    }
}

private struct DeviceInspector: View {
    @Environment(AppModel.self) private var model
    let device: Device?
    @State private var name = ""

    var body: some View {
        if let d = device {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: d.symbol)
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                            .frame(width: 44)
                        VStack(alignment: .leading) {
                            Text(d.displayName).font(.headline)
                            Text(d.kindLabel).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("名前") {
                    TextField("名前", text: $name, prompt: Text("例: リビングのテレビ"))
                        .onSubmit { model.monitor.devices.rename(d.mac, to: name) }
                    Text("自分で付けた名前は data フォルダの device_names.json に保存されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("詳細") {
                    LabeledContent("IPアドレス", value: d.ip ?? "—")
                    LabeledContent("MACアドレス") { Text(d.mac).font(.callout.monospaced()).textSelection(.enabled) }
                    LabeledContent("メーカー（OUI）", value: d.vendor ?? "不明")
                    LabeledContent("mDNS 名", value: d.mdns ?? "—")
                    LabeledContent("初めて見た", value: d.firstSeen.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("最後に見た", value: d.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
                if d.random == true {
                    Section {
                        Text("プライベート Wi-Fi アドレス（ランダム化されたMAC）です。iPhone・iPad・Mac などは、ネットワークごとに別のアドレスを使うため、メーカー名が分かりません。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { name = d.name ?? "" }
            .onChange(of: d.id) { name = d.name ?? "" }
        } else {
            ContentUnavailableView("機器を選択", systemImage: "cursorarrow.click.2", description: Text("一覧から機器を選ぶと詳細を表示し、名前を付けられます。"))
        }
    }
}
