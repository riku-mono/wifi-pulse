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
                    Card { ObservationRow(level: .warn, text: String(localized: "スキャンできませんでした"), detail: e) }
                }
                if scanner.lastScan == nil {
                    Card {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(scanner.isScanning ? "周辺をスキャンしています…" : "まだスキャンしていません")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                    }
                } else {
                    summary(all, loads: loads, recs: recs, myChannel: myChannel)
                    Card("スペクトラム", systemImage: "waveform",
                         subtitle: String(localized: "各アクセスポイントが電波を出している幅（チャンネル幅）と強さ。重なっている部分は電波を取り合います。グラフの上をなぞると、そのチャンネルに重なっているネットワークを表示します。")) {
                        SpectrumChart(aps: all, band: band, mySSID: mySSID).equatable()
                            .frame(height: 300)
                    }
                    Card("チャンネルごとの混雑度", systemImage: "chart.bar.fill",
                         subtitle: String(localized: "そのチャンネルに重なっているほかのネットワークの影響の合計（電波が強い・利用率が高いほど大きい）。自分のネットワークは除いています。")) {
                        CongestionChart(loads: loads, recommended: recs.map(\.channel), band: band).equatable()
                            .frame(height: 200)
                        recommendationText(recs, loads: loads, myChannel: myChannel)
                    }
                    Card("アクセスポイント", systemImage: "list.bullet",
                         subtitle: String(localized: "\(Set(all.map(\.sortName)).count) 個のネットワーク · \(all.count) 台のアクセスポイント")) {
                        APTable(aps: filtered.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder, mySSID: mySSID)
                            .frame(minHeight: 320)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("周辺の Wi-Fi")
        .searchable(text: $search, placement: .toolbar, prompt: "SSID・BSSID・メーカー")
        .inspector(isPresented: $showInspector) {
            APInspector(ap: all.first { $0.id == selection } ?? scanner.accessPoints.first { $0.id == selection })
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .onChange(of: selection) { if selection != nil { showInspector = true } }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("バンド", selection: $band) {
                    ForEach(Band.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("自動スキャン", selection: $scanner.autoInterval) {
                        ForEach(NeighborScanner.AutoInterval.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle("直近10分に見えたものも表示", isOn: $includeStale)
                } label: {
                    Label("表示オプション", systemImage: scanner.autoInterval == .off ? "timer" : "timer.circle.fill")
                }
                .help("スキャン中は自分の通信も数百ms止まるため、自動スキャンは必要なときだけ使ってください")
                Button {
                    Task { await scanner.scan() }
                } label: {
                    Label("スキャン", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isScanning)
                .help("周辺のアクセスポイントをスキャンします（15秒以上あけて実行）")
                Button {
                    showInspector.toggle()
                } label: {
                    Label("インスペクタ", systemImage: "sidebar.trailing")
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
            MetricTile(title: "ネットワーク", systemImage: "wifi", value: "\(Set(aps.map(\.sortName)).count)",
                       caption: String(localized: "アクセスポイント \(aps.count) 台"))
            MetricTile(title: "自分のチャンネル", systemImage: "scope",
                       value: myChannel.map { "\($0)ch" } ?? "—",
                       caption: mine.map { String(localized: "重なるネットワーク \($0.count) 件") } ?? String(localized: "このバンドには接続していません"),
                       level: mine?.level ?? .none)
            MetricTile(title: "いちばん空いている", systemImage: "star",
                       value: recs.first.map { "\($0.channel)ch" } ?? "—",
                       caption: recs.first.map { $0.isDFS ? String(localized: "DFS 対象（レーダー検出で停止あり）") : (band.dfsLabel($0.channel).map { String(localized: "\($0)・DFSなし") } ?? String(localized: "重なり \($0.count) 件")) },
                       level: recs.first == nil ? .none : .good)
            MetricTile(title: "最終スキャン", systemImage: "clock",
                       value: scanner.lastScan.map { Fmt.time($0) } ?? "—",
                       caption: String(localized: "所要 \(String(format: "%.1f", scanner.lastDuration)) 秒 · \(scanner.scanCount) 回目"))
        }
    }

    @ViewBuilder
    private func recommendationText(_ recs: [ChannelLoad], loads: [ChannelLoad], myChannel: Int?) -> some View {
        if let best = recs.first {
            let mine = loads.first { $0.channel == myChannel }
            VStack(alignment: .leading, spacing: 6) {
                ObservationRow(level: .good,
                               text: String(localized: "空いている順: ") + recs.map { "\($0.channel)ch" + (band.dfsLabel($0.channel).map { String(localized: "（\($0)）") } ?? "") }.joined(separator: "、"))
                if let mine, mine.score > best.score + 0.5 {
                    ObservationRow(level: .warn,
                                   text: String(localized: "いまの \(mine.channel)ch より \(best.channel)ch の方が空いています。"),
                                   detail: String(localized: "ルーターの設定でチャンネルを変えると改善する可能性があります。変えたら、しばらくしてからもう一度スキャンして確かめてください。"))
                }
                if band == .ghz5 {
                    Text("W53（52〜64ch）・W56（100〜144ch）は DFS 対象で、レーダーを検出するとルーターが最大60秒送信を止めます。安定性を優先するなら W52（36〜48ch）を選びます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if band == .ghz24 {
                    Text("2.4GHz は隣のチャンネルと電波が重なるため、1・6・11ch のどれかを選ぶのが基本です。")
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
                    AreaMark(x: .value("チャンネル", v.x), yStart: .value("下限", -100), yEnd: .value("dBm", v.y),
                             series: .value("AP", v.ap))
                        .foregroundStyle(color.opacity(isMine ? 0.28 : 0.10))
                    LineMark(x: .value("チャンネル", v.x), y: .value("dBm", v.y), series: .value("AP", v.ap))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: isMine ? 2.5 : 1.2))
                }
                if labeled.contains(ap.id) {
                    PointMark(x: .value("チャンネル", ap.center), y: .value("dBm", ap.rssi))
                        .symbolSize(0)
                        .annotation(position: .top, spacing: 2) {
                            Text(ap.isHidden ? String(localized: "（非公開）") : ap.ssid!)
                                .font(.caption2.weight(isMine ? .bold : .regular))
                                .foregroundStyle(isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                        }
                }
            }
            if let ch = selectedChannel {
                RuleMark(x: .value("選択", ch))
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
        .chartXAxisLabel("チャンネル")
        .chartYAxisLabel("dBm")
        .chartXSelection(value: $selectedX)
        .transaction { $0.animation = nil }
        .overlay {
            if aps.isEmpty {
                ContentUnavailableView("このバンドのアクセスポイントは見つかりません", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        }
    }

    private func channelPopover(_ ch: Int) -> some View {
        let over = aps.filter { $0.overlaps(channel: ch) }.sorted { $0.rssi > $1.rssi }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(ch)ch" + (band.dfsLabel(ch).map { String(localized: "（\($0)）") } ?? "")).font(.caption.weight(.semibold))
            if over.isEmpty {
                Text("重なるネットワークなし").font(.caption2).foregroundStyle(.secondary)
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
            if over.count > 6 { Text("ほか \(over.count - 6) 件").font(.caption2).foregroundStyle(.secondary) }
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
            BarMark(x: .value("チャンネル", "\(l.channel)"), y: .value("混雑度", l.score))
                .foregroundStyle(l.level.tint.opacity(l.isDFS ? 0.5 : 0.9))
                .annotation(position: .top, spacing: 2) {
                    if l.isMine {
                        Image(systemName: "wifi").font(.caption2).foregroundStyle(.tint)
                            .accessibilityLabel("現在のチャンネル")
                    } else if recommended.first == l.channel {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.green)
                            .accessibilityLabel("おすすめ")
                    }
                }
        }
        .chartXAxisLabel("チャンネル（薄い色は DFS 対象・\(Image(systemName: "wifi")) は現在・\(Image(systemName: "star.fill")) はおすすめ）")
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
            TableColumn("ネットワーク", value: \.sortName) { ap in
                HStack(spacing: 6) {
                    if mySSID != nil && ap.ssid == mySSID {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("接続中")
                    }
                    Text(ap.displayName).foregroundStyle(ap.isHidden ? .secondary : .primary)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("電波", value: \.rssi) { ap in
                HStack(spacing: 6) {
                    Gauge(value: Double(ap.rssi + 100), in: 0...70) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(Level.rssi(ap.rssi).tint)
                        .frame(width: 40)
                    Text("\(ap.rssi)").monospacedDigit()
                }
            }
            .width(90)
            TableColumn("チャンネル", value: \.channel) { ap in
                HStack(spacing: 4) {
                    Text("\(ap.channel)").monospacedDigit()
                    Text("· \(ap.width) MHz").foregroundStyle(.secondary)
                    if ap.isDFS { Text("DFS").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("規格", value: \.sortGeneration) { Text($0.generationLabel) }
                .width(70)
            TableColumn("セキュリティ", value: \.security) { ap in
                Text(ap.security).foregroundStyle(ap.isInsecure ? .orange : .primary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("端末数", value: \.sortStations) { Text($0.stations.map(String.init) ?? "—").monospacedDigit() }
                .width(55)
            TableColumn("利用率", value: \.sortUtilization) { Text($0.utilization.map { "\(Int($0 * 100))%" } ?? "—").monospacedDigit() }
                .width(55)
            TableColumn("メーカー", value: \.sortVendor) { Text($0.vendor ?? "—").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 140)
            TableColumn("BSSID") { Text($0.bssid ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary) }
                .width(min: 110, ideal: 130)
            TableColumn("最終確認", value: \.lastSeen) { Text(Fmt.time($0.lastSeen)).monospacedDigit().foregroundStyle(.secondary) }
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
                Section("電波の推移（スキャンごと）") {
                    Chart(ap.history, id: \.date) { p in
                        LineMark(x: .value("時刻", p.date), y: .value("dBm", p.rssi))
                        PointMark(x: .value("時刻", p.date), y: .value("dBm", p.rssi)).symbolSize(12)
                    }
                    .chartYScale(domain: -100 ... -20)
                    .frame(height: 120)
                }
                Section("電波") {
                    LabeledContent("電波強度", value: "\(ap.rssi) dBm")
                    LabeledContent("ノイズ", value: "\(ap.noise) dBm")
                    LabeledContent("SN比", value: "\(ap.rssi - ap.noise) dB")
                    LabeledContent("使用範囲", value: String(format: String(localized: "%.0f〜%.0f ch（中心 %.0f）"), ap.span.lowerBound + 2, ap.span.upperBound - 2, ap.center))
                    if let dfs = ap.band.dfsLabel(ap.channel) { LabeledContent("区分", value: dfs + (ap.isDFS ? String(localized: "（DFS）") : "")) }
                }
                Section("混雑（BSS Load）") {
                    LabeledContent("接続端末数", value: ap.stations.map { String(localized: "\($0) 台") } ?? String(localized: "非公開"))
                    LabeledContent("チャンネル利用率", value: ap.utilization.map { "\(Int($0 * 100))%" } ?? String(localized: "非公開"))
                    Text("アクセスポイント自身が知らせている値です。対応していない機種では表示されません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("詳細") {
                    LabeledContent("規格", value: ap.generationLabel)
                    LabeledContent("セキュリティ", value: ap.security)
                    LabeledContent("BSSID") { Text(ap.bssid ?? "—").font(.callout.monospaced()).textSelection(.enabled) }
                    LabeledContent("メーカー", value: ap.vendor ?? String(localized: "不明"))
                    LabeledContent("国コード", value: ap.country ?? "—")
                    LabeledContent("ビーコン間隔", value: "\(ap.beaconInterval) TU")
                    LabeledContent("初めて見た", value: ap.firstSeen.formatted(date: .omitted, time: .standard))
                    LabeledContent("最後に見た", value: ap.lastSeen.formatted(date: .omitted, time: .standard))
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("アクセスポイントを選択", systemImage: "cursorarrow.click.2",
                                   description: Text("一覧から選ぶと、詳細と電波の推移を表示します。"))
        }
    }
}
