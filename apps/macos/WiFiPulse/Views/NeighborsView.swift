import Charts
import SwiftUI

struct NeighborsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("neighborBand") private var band: Band = .ghz5
    @State private var includeStale = false
    @State private var search = ""
    @State private var selection: AccessPoint.ID?
    @State private var showInspector = false
    @State private var sortOrder = [KeyPathComparator(\AccessPoint.rssi, order: .reverse)]

    var body: some View {
        @Bindable var scanner = model.neighbors
        let conn = model.monitor.connection
        let mySSID = conn.ssid
        let myChannel = conn.band == band.rawValue ? conn.channel : nil
        let all = scanner.visible(band: band, includeStale: includeStale)
        let filtered = search.isEmpty ? all : all.filter {
            [$0.ssid ?? "", $0.bssid ?? "", $0.vendor ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
        }
        let loads = NeighborScanner.channelLoads(all, band: band, mySSID: mySSID, myChannel: myChannel)
        let recs = NeighborScanner.recommendations(loads, band: band)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.location.isAuthorized {
                    LocationBanner()
                }
                if let e = scanner.error {
                    Card { ObservationRow(level: .warn, text: String(localized: "Scan failed"), detail: e) }
                }
                if scanner.lastScan == nil {
                    Card {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(scanner.isScanning ? "Scanning nearby networks…" : "Not scanned yet")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                    }
                } else {
                    summary(all, loads: loads, recs: recs, myChannel: myChannel)
                    Card("Spectrum", systemImage: "waveform",
                         subtitle: String(localized: "The width (channel width) and strength of each access point’s signal. Overlapping networks compete for airtime. Hover over the chart to see which networks overlap that channel.")) {
                        SpectrumChart(aps: all, band: band, mySSID: mySSID).equatable()
                            .frame(height: 300)
                    }
                    Card("Congestion by Channel", systemImage: "chart.bar.fill",
                         subtitle: String(localized: "The combined impact of other networks overlapping each channel (higher for stronger signals and busier networks). Your own network is excluded.")) {
                        CongestionChart(loads: loads, recommended: recs.map(\.channel), band: band).equatable()
                            .frame(height: 200)
                        recommendationText(recs, loads: loads, myChannel: myChannel)
                    }
                    Card("Access Points", systemImage: "list.bullet",
                         subtitle: String(localized: "Networks: \(Set(all.map(\.sortName)).count) · Access points: \(all.count)")) {
                        APTable(aps: filtered.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder, mySSID: mySSID)
                            .frame(minHeight: 320)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Nearby Wi-Fi")
        .searchable(text: $search, placement: .toolbar, prompt: "SSID, BSSID, Manufacturer")
        .inspector(isPresented: $showInspector) {
            APInspector(ap: all.first { $0.id == selection } ?? scanner.accessPoints.first { $0.id == selection })
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .onChange(of: selection) { if selection != nil { showInspector = true } }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Band", selection: $band) {
                    ForEach(Band.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Auto-Scan", selection: $scanner.autoInterval) {
                        ForEach(NeighborScanner.AutoInterval.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle("Include Networks Seen in the Last 10 Minutes", isOn: $includeStale)
                } label: {
                    Label("View Options", systemImage: scanner.autoInterval == .off ? "timer" : "timer.circle.fill")
                }
                .help("Each scan pauses your own traffic for a few hundred milliseconds, so use auto-scan only when needed")
                Button {
                    Task { await scanner.scan() }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isScanning)
                .help("Scan for nearby access points (at least 15 seconds apart)")
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .task {
            if scanner.lastScan.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                await scanner.scan()
            }
        }
    }

    private func summary(_ aps: [AccessPoint], loads: [ChannelLoad], recs: [ChannelLoad], myChannel: Int?) -> some View {
        let scanner = model.neighbors
        let mine = loads.first { $0.channel == myChannel }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            MetricTile(title: "Network", systemImage: "wifi", value: "\(Set(aps.map(\.sortName)).count)",
                       caption: String(localized: "Access points: \(aps.count)"))
            MetricTile(title: "Your Channel", systemImage: "scope",
                       value: myChannel.map { "\($0)ch" } ?? "—",
                       caption: mine.map { String(localized: "Overlapping networks: \($0.count)") } ?? String(localized: "Not connected on this band"),
                       level: mine?.level ?? .none)
            MetricTile(title: "Least Congested", systemImage: "star",
                       value: recs.first.map { "\($0.channel)ch" } ?? "—",
                       caption: recs.first.map { $0.isDFS ? String(localized: "DFS channel (pauses when radar is detected)") : (band.dfsLabel($0.channel).map { String(localized: "\($0) · no DFS") } ?? String(localized: "Overlaps: \($0.count)")) },
                       level: recs.first == nil ? .none : .good)
            MetricTile(title: "Last Scan", systemImage: "clock",
                       value: scanner.lastScan.map { Fmt.time($0) } ?? "—",
                       caption: String(localized: "Took \(String(format: "%.1f", scanner.lastDuration)) s · Scan #\(scanner.scanCount)"))
        }
    }

    @ViewBuilder
    private func recommendationText(_ recs: [ChannelLoad], loads: [ChannelLoad], myChannel: Int?) -> some View {
        if let best = recs.first {
            let mine = loads.first { $0.channel == myChannel }
            VStack(alignment: .leading, spacing: 6) {
                ObservationRow(level: .good,
                               text: String(localized: "Least congested: \(recs.map { "\($0.channel)ch" + (band.dfsLabel($0.channel).map { String(localized: " (\($0))") } ?? "") }.formatted(.list(type: .and)))"))
                if let mine, mine.score > best.score + 0.5 {
                    ObservationRow(level: .warn,
                                   text: String(localized: "Channel \(best.channel) is less congested than your current channel \(mine.channel)."),
                                   detail: String(localized: "Changing the channel in your router’s settings may help. After changing it, wait a while and scan again to confirm."))
                }
                if band == .ghz5 {
                    Text("W53 (channels 52–64) and W56 (100–144) are DFS channels: when radar is detected, the router stops transmitting for up to 60 seconds. For stability, choose W52 (channels 36–48).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if band == .ghz24 {
                    Text("On 2.4 GHz, neighboring channels overlap, so stick to channel 1, 6, or 11.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Spectrum

private struct SpectrumChart: View, Equatable {
    let aps: [AccessPoint]
    let band: Band
    let mySSID: String?
    @State private var selectedX: Double?

    static func == (a: Self, b: Self) -> Bool { a.aps == b.aps && a.band == b.band && a.mySSID == b.mySSID }

    struct Vertex: Identifiable {
        let id: String
        let ap: String
        let x: Double
        let y: Int
    }

    var body: some View {
        let domain = xDomain
        let labeled = Set(aps.sorted { $0.rssi > $1.rssi }.prefix(10).map(\.id))
        let selectedChannel = selectedX.flatMap { x in band.channels.min { abs(Double($0) - x) < abs(Double($1) - x) } }

        Chart {
            ForEach(aps) { ap in
                let color = color(for: ap)
                let isMine = mySSID != nil && ap.ssid == mySSID
                ForEach(vertices(ap)) { v in
                    AreaMark(x: .value("Channel", v.x), yStart: .value("Floor", -100), yEnd: .value("dBm", v.y),
                             series: .value("AP", v.ap))
                        .foregroundStyle(color.opacity(isMine ? 0.28 : 0.10))
                    LineMark(x: .value("Channel", v.x), y: .value("dBm", v.y), series: .value("AP", v.ap))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: isMine ? 2.5 : 1.2))
                }
                if labeled.contains(ap.id) {
                    PointMark(x: .value("Channel", ap.center), y: .value("dBm", ap.rssi))
                        .symbolSize(0)
                        .annotation(position: .top, spacing: 2) {
                            Text(ap.isHidden ? String(localized: "(hidden)") : ap.ssid!)
                                .font(.caption2.weight(isMine ? .bold : .regular))
                                .foregroundStyle(isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                        }
                }
            }
            if let ch = selectedChannel {
                RuleMark(x: .value("Selection", ch))
                    .foregroundStyle(.primary.opacity(0.35))
                    .annotation(position: .top, alignment: .center, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        channelPopover(ch)
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: -100 ... -20)
        .chartXAxis {
            AxisMarks(values: band.channels.filter { band == .ghz5 || band == .ghz24 || $0 % 8 == 1 }) { v in
                AxisGridLine()
                AxisValueLabel { if let c = v.as(Int.self) { Text("\(c)") } }
            }
        }
        .chartXAxisLabel("Channel")
        .chartYAxisLabel("dBm")
        .chartXSelection(value: $selectedX)
        .transaction { $0.animation = nil }
        .overlay {
            if aps.isEmpty {
                ContentUnavailableView("No Access Points on This Band", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        }
    }

    private func channelPopover(_ ch: Int) -> some View {
        let over = aps.filter { $0.overlaps(channel: ch) }.sorted { $0.rssi > $1.rssi }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(ch)ch" + (band.dfsLabel(ch).map { String(localized: " (\($0))") } ?? "")).font(.caption.weight(.semibold))
            if over.isEmpty {
                Text("No overlapping networks").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(over.prefix(6)) { ap in
                HStack(spacing: 6) {
                    Circle().fill(color(for: ap)).frame(width: 6, height: 6)
                    Text(ap.displayName).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(ap.rssi)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
            if over.count > 6 { Text("+\(over.count - 6) more").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(8)
        .frame(width: 200)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }

    /// 台形: 裾は帯域の端、上辺は端から 1ch 内側
    private func vertices(_ ap: AccessPoint) -> [Vertex] {
        let s = ap.span
        let inset = min(1.0, (s.upperBound - s.lowerBound) / 4)
        return [
            Vertex(id: "\(ap.id)-0", ap: ap.id, x: s.lowerBound, y: -100),
            Vertex(id: "\(ap.id)-1", ap: ap.id, x: s.lowerBound + inset, y: ap.rssi),
            Vertex(id: "\(ap.id)-2", ap: ap.id, x: s.upperBound - inset, y: ap.rssi),
            Vertex(id: "\(ap.id)-3", ap: ap.id, x: s.upperBound, y: -100),
        ]
    }

    private var xDomain: ClosedRange<Double> {
        let base: ClosedRange<Double> = switch band {
        case .ghz24: -1...15
        case .ghz5: 32...148
        case .ghz6: -3...97
        }
        let lo = min(base.lowerBound, aps.map(\.span.lowerBound).min() ?? base.lowerBound)
        let hi = max(base.upperBound, aps.map(\.span.upperBound).max() ?? base.upperBound)
        return lo...hi
    }

    private func color(for ap: AccessPoint) -> Color {
        if let mySSID, ap.ssid == mySSID { return .accentColor }
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .mint, .indigo, .brown, .cyan, .red]
        var h: UInt32 = 5381
        for b in (ap.ssid ?? ap.id).utf8 { h = (h &* 33) &+ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }
}

// MARK: - Congestion

private struct CongestionChart: View, Equatable {
    let loads: [ChannelLoad]
    let recommended: [Int]
    let band: Band

    var body: some View {
        Chart(loads) { l in
            BarMark(x: .value("Channel", "\(l.channel)"), y: .value("Congestion", l.score))
                .foregroundStyle(l.level.tint.opacity(l.isDFS ? 0.5 : 0.9))
                .annotation(position: .top, spacing: 2) {
                    if l.isMine {
                        Image(systemName: "wifi").font(.caption2).foregroundStyle(.tint)
                            .accessibilityLabel("Current channel")
                    } else if recommended.first == l.channel {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.green)
                            .accessibilityLabel("Recommended")
                    }
                }
        }
        .chartXAxisLabel("Channel (faded = DFS, \(Image(systemName: "wifi")) = current, \(Image(systemName: "star.fill")) = recommended)")
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f", d)) } }
            }
        }
        .transaction { $0.animation = nil }
    }
}

// MARK: - Table

private struct APTable: View {
    let aps: [AccessPoint]
    @Binding var selection: AccessPoint.ID?
    @Binding var sortOrder: [KeyPathComparator<AccessPoint>]
    let mySSID: String?

    var body: some View {
        Table(aps, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Network", value: \.sortName) { ap in
                HStack(spacing: 6) {
                    if mySSID != nil && ap.ssid == mySSID {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("Connected")
                    }
                    Text(ap.displayName).foregroundStyle(ap.isHidden ? .secondary : .primary)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Signal", value: \.rssi) { ap in
                HStack(spacing: 6) {
                    Gauge(value: Double(ap.rssi + 100), in: 0...70) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(Level.rssi(ap.rssi).tint)
                        .frame(width: 40)
                    Text("\(ap.rssi)").monospacedDigit()
                }
            }
            .width(90)
            TableColumn("Channel", value: \.channel) { ap in
                HStack(spacing: 4) {
                    Text("\(ap.channel)").monospacedDigit()
                    Text("· \(ap.width) MHz").foregroundStyle(.secondary)
                    if ap.isDFS { Text("DFS").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("Standard", value: \.sortGeneration) { Text($0.generationLabel) }
                .width(70)
            TableColumn("Security", value: \.security) { ap in
                Text(ap.security).foregroundStyle(ap.isInsecure ? .orange : .primary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Clients", value: \.sortStations) { Text($0.stations.map(String.init) ?? "—").monospacedDigit() }
                .width(55)
            TableColumn("Utilization", value: \.sortUtilization) { Text($0.utilization.map { "\(Int($0 * 100))%" } ?? "—").monospacedDigit() }
                .width(55)
            TableColumn("Manufacturer", value: \.sortVendor) { Text($0.vendor ?? "—").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 140)
            TableColumn("BSSID") { Text($0.bssid ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary) }
                .width(min: 110, ideal: 130)
            TableColumn("Last Seen", value: \.lastSeen) { Text(Fmt.time($0.lastSeen)).monospacedDigit().foregroundStyle(.secondary) }
                .width(70)
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Inspector

private struct APInspector: View {
    let ap: AccessPoint?

    var body: some View {
        if let ap {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ap.displayName).font(.title3.weight(.semibold))
                        Text("\(ap.band.label) · \(ap.channel)ch · \(ap.width) MHz").foregroundStyle(.secondary)
                    }
                }
                Section("Signal History (per Scan)") {
                    Chart(ap.history, id: \.date) { p in
                        LineMark(x: .value("Time", p.date), y: .value("dBm", p.rssi))
                        PointMark(x: .value("Time", p.date), y: .value("dBm", p.rssi)).symbolSize(12)
                    }
                    .chartYScale(domain: -100 ... -20)
                    .frame(height: 120)
                }
                Section("Signal") {
                    LabeledContent("Signal Strength", value: "\(ap.rssi) dBm")
                    LabeledContent("Noise", value: "\(ap.noise) dBm")
                    LabeledContent("SNR", value: "\(ap.rssi - ap.noise) dB")
                    LabeledContent("Occupied Range", value: String(format: String(localized: "ch %.0f–%.0f (center %.0f)"), ap.span.lowerBound + 2, ap.span.upperBound - 2, ap.center))
                    if let dfs = ap.band.dfsLabel(ap.channel) { LabeledContent("Band Group", value: dfs + (ap.isDFS ? String(localized: " (DFS)") : "")) }
                }
                Section("Load (BSS Load)") {
                    LabeledContent("Connected Clients", value: ap.stations.map { String(localized: "\($0)") } ?? String(localized: "Not reported"))
                    LabeledContent("Channel Utilization", value: ap.utilization.map { "\(Int($0 * 100))%" } ?? String(localized: "Not reported"))
                    Text("Reported by the access point itself. Not shown for models that don’t support it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Details") {
                    LabeledContent("Standard", value: ap.generationLabel)
                    LabeledContent("Security", value: ap.security)
                    LabeledContent("BSSID") { Text(ap.bssid ?? "—").font(.callout.monospaced()).textSelection(.enabled) }
                    LabeledContent("Manufacturer", value: ap.vendor ?? String(localized: "Unknown"))
                    LabeledContent("Country Code", value: ap.country ?? "—")
                    LabeledContent("Beacon Interval", value: "\(ap.beaconInterval) TU")
                    LabeledContent("First Seen", value: ap.firstSeen.formatted(date: .omitted, time: .standard))
                    LabeledContent("Last Seen", value: ap.lastSeen.formatted(date: .omitted, time: .standard))
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select an Access Point", systemImage: "cursorarrow.click.2",
                                   description: Text("Select one in the list to see details and signal history."))
        }
    }
}
