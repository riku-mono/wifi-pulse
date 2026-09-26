import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Device.ID?
    @State private var search = ""
    @State private var showOffline = false
    @State private var showInspector = true

    var body: some View {
        let scanner = model.monitor.devices
        // 別の場所（ネットワーク）で見た機器は出さない
        let network = model.monitor.network
        let all = scanner.devices.filter { $0.net == network }
        let list = all.filter { d in
            (showOffline || d.online == true)
                && (search.isEmpty || [d.displayName, d.ip ?? "", d.mac, d.vendor ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }

        Group {
            if all.isEmpty {
                ContentUnavailableView {
                    Label(scanner.isSweeping ? "Looking for Devices…" : "No Devices Found", systemImage: "network")
                } description: {
                    Text(scanner.arpWorks
                         ? "Sends one probe to each address on your local network and lists the devices that respond."
                         : "Local network access may not be allowed. Check System Settings › Privacy & Security › Local Network.")
                } actions: {
                    Button("Find") { scanner.requestSweep() }
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
                    TableColumn("Name") { d in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.displayName).fontWeight(d.name != nil ? .semibold : .regular)
                            if d.ip == model.monitor.env.gateway {
                                Text("Router for this network").font(.caption).foregroundStyle(.secondary)
                            } else if d.ip == model.monitor.env.selfIP {
                                Text("This Mac").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("IP Address") { Text($0.ip ?? "—").monospacedDigit() }
                        .width(min: 100, ideal: 120)
                    TableColumn("Manufacturer") { d in
                        Text(d.vendor_ja ?? d.vendor ?? (d.random == true ? String(localized: "Private Address") : String(localized: "Unknown")))
                            .foregroundStyle(d.vendor == nil ? .secondary : .primary)
                    }
                    TableColumn("Type") { Text($0.kindLabel) }
                        .width(min: 70, ideal: 90)
                    TableColumn("Status") { d in
                        if d.online == true {
                            Label("Online", systemImage: "circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon).imageScale(.small)
                        } else {
                            Text(d.lastSeen, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 90, ideal: 110)
                }
                .contextMenu(forSelectionType: Device.ID.self) { ids in
                    if let mac = ids.first {
                        Button("Copy MAC Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(mac, forType: .string)
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .searchable(text: $search, placement: .toolbar, prompt: "Name, IP, Manufacturer")
        .inspector(isPresented: $showInspector) {
            DeviceInspector(device: all.first { $0.id == selection })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $showOffline) {
                    Label("Show Offline Devices", systemImage: "clock.arrow.circlepath")
                }
                .help("Also show devices found earlier")
                Button {
                    scanner.requestSweep()
                } label: {
                    Label("Find", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isSweeping)
                .help("Probe every address on the local network and refresh the list")
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
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
                Section("Name") {
                    TextField("Name", text: $name, prompt: Text("e.g. Living Room TV"))
                        .onSubmit { model.monitor.devices.rename(d.mac, to: name) }
                    Text("Names you assign are saved to device_names.json in the data folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Details") {
                    LabeledContent("IP Address", value: d.ip ?? "—")
                    LabeledContent("MAC Address") { Text(d.mac).font(.callout.monospaced()).textSelection(.enabled) }
                    LabeledContent("Manufacturer (OUI)", value: d.vendor ?? String(localized: "Unknown"))
                    LabeledContent("mDNS Name", value: d.mdns ?? "—")
                    LabeledContent("First Seen", value: d.firstSeen.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Last Seen", value: d.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
                if d.random == true {
                    Section {
                        Text("This is a private Wi-Fi address (randomized MAC). iPhone, iPad, Mac, and others use a different address on each network, so the manufacturer can’t be identified.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { name = d.name ?? "" }
            .onChange(of: d.id) { name = d.name ?? "" }
        } else {
            ContentUnavailableView("Select a Device", systemImage: "cursorarrow.click.2", description: Text("Select a device in the list to see details and give it a name."))
        }
    }
}
