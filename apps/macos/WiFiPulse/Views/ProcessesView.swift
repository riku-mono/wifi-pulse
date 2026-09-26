import Charts
import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: TrafficRow.ID?
    @State private var showInspector = true
    @State private var activeOnly = true
    @State private var search = ""
    /// 既定は「ならした通信量」順。瞬間値で並べると2秒ごとに行が入れ替わって読めない
    @State private var sortOrder = [KeyPathComparator(\TrafficRow.smoothedRate, order: .reverse)]

    var body: some View {
        @Bindable var pm = model.processes
        let now = pm.lastUpdate ?? Date()
        let rows = pm.rows.filter { row in
            (!activeOnly || pm.isRecentlyActive(row, now: now))
                && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search))
        }
        // 同じ値の行どうしは名前順に固定して、並びが揺れないようにする
        .sorted(using: sortOrder + [KeyPathComparator(\TrafficRow.name), KeyPathComparator(\TrafficRow.id)])

        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("アプリ / プロセス", value: \.name) { row in
                    HStack(spacing: 8) {
                        if let icon = pm.icon(for: row) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "gearshape").frame(width: 18, height: 18).foregroundStyle(.secondary)
                        }
                        Text(row.name).lineLimit(1)
                        if row.pids.count > 1 {
                            Text("\(row.pids.count)").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).background(.quaternary, in: .capsule)
                                .help("\(row.pids.count) 個のプロセスをまとめて表示しています")
                        }
                    }
                }
                .width(min: 180, ideal: 240)
                TableColumn("受信", value: \.rxRate) { Text(Rate.text($0.rxRate)).monospacedDigit().foregroundStyle(Rate.style($0.rxRate)) }
                    .width(min: 70, ideal: 85)
                TableColumn("送信", value: \.txRate) { Text(Rate.text($0.txRate)).monospacedDigit().foregroundStyle(Rate.style($0.txRate)) }
                    .width(min: 70, ideal: 85)
                TableColumn("累計", value: \.total) { row in
                    Text("↓\(Rate.bytes(row.rxTotal)) ↑\(Rate.bytes(row.txTotal))").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
                TableColumn("接続", value: \.connectionCount) { row in
                    Text(row.connectionCount == 0 ? "—" : "\(row.established)/\(row.connectionCount)").monospacedDigit()
                }
                .width(55)
                TableColumn("RTT", value: \.rttSort) { Text($0.rtt.map { "\(Fmt.ms($0)) ms" } ?? "—").monospacedDigit() }
                    .width(70)
                TableColumn("再送", value: \.retransmitTotal) { row in
                    Text(row.retransmitTotal == 0 ? "—" : Rate.bytes(row.retransmitTotal))
                        .monospacedDigit()
                        .foregroundStyle(row.retransmitTotal > 0 ? .orange : .secondary)
                }
                .width(70)
            }
            .overlay {
                if let failure = pm.failure {
                    ContentUnavailableView("通信量を取得できません", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if !pm.isRunning {
                    ContentUnavailableView("計測を開始しています…", systemImage: "app.connected.to.app.below.fill")
                } else if pm.lastUpdate == nil {
                    ProgressView("最初のデータを待っています…")
                } else if rows.isEmpty {
                    ContentUnavailableView(activeOnly ? "いま通信しているアプリはありません" : "該当するアプリはありません",
                                           systemImage: "app.connected.to.app.below.fill")
                }
            }
        }
        .navigationTitle("アプリの通信")
        .searchable(text: $search, placement: .toolbar, prompt: "アプリ名")
        .inspector(isPresented: $showInspector) {
            ProcessInspector(row: pm.rows.first { $0.id == selection })
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $pm.groupByApp) {
                    Label("アプリごとにまとめる", systemImage: "square.stack.3d.up")
                }
                .help("ヘルパープロセスを親のアプリにまとめて表示します")
                Toggle(isOn: $activeOnly) {
                    Label("通信中のみ", systemImage: "line.3.horizontal.decrease")
                }
                .help("直近\(Int(ProcessMonitor.lingerSeconds))秒以内に通信があったものだけを表示します")
                Button {
                    showInspector.toggle()
                } label: {
                    Label("インスペクタ", systemImage: "sidebar.trailing")
                }
            }
        }
        // nettop は画面を開いている間だけ動かす
        .onAppear { pm.start() }
        .onDisappear { pm.stop() }
    }

    private var header: some View {
        let pm = model.processes
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    stat("受信", Rate.text(pm.totalRx), "arrow.down.circle", SeriesColor.rx)
                    stat("送信", Rate.text(pm.totalTx), "arrow.up.circle", SeriesColor.tx)
                    stat("接続", "\(pm.connectionCount)", "point.3.connected.trianglepath.dotted", .secondary)
                }
                Text("nettop で \(ProcessMonitor.interval) 秒ごとに集計。累計はこの画面を開いてからの量です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            TopTalkersChart(history: pm.history, names: Dictionary(pm.rows.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
                .equatable()
                .frame(height: 110)
        }
    }

    private func stat(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
    }
}

enum Rate {
    static func text(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "—" : Int64(bytesPerSecond).formatted(.byteCount(style: .binary)) + "/s"
    }
    static func bytes(_ b: Int64) -> String {
        b == 0 ? "0" : b.formatted(.byteCount(style: .binary))
    }
    static func style(_ v: Double) -> some ShapeStyle {
        v >= 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }
}

/// 直近5分の通信量の多い上位5アプリ（積み上げ）。
/// 10秒ごとの平均にまとめ、区間が確定したときだけ描き直す（2秒ごとに150点×6系列を描くと重いため）。
private struct TopTalkersChart: View, Equatable {
    static let bucket: TimeInterval = 10

    struct Bucket: Equatable {
        let date: Date
        let rates: [String: Double]
    }
    let buckets: [Bucket]
    let names: [String: String]

    init(history: [(date: Date, rates: [String: Double])], names: [String: String]) {
        var groups: [(Date, [[String: Double]])] = []
        for h in history {
            let t = h.date.timeIntervalSince1970
            let start = Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: Self.bucket))
            if groups.last?.0 == start { groups[groups.count - 1].1.append(h.rates) } else { groups.append((start, [h.rates])) }
        }
        if !groups.isEmpty { groups.removeLast() } // まだ途中の区間は描かない
        buckets = groups.map { start, samples in
            var sum: [String: Double] = [:]
            for r in samples { for (k, v) in r { sum[k, default: 0] += v } }
            return Bucket(date: start, rates: sum.mapValues { $0 / Double(samples.count) })
        }
        let used = Set(buckets.flatMap(\.rates.keys))
        self.names = names.filter { used.contains($0.key) }
    }

    static func == (a: Self, b: Self) -> Bool { a.buckets == b.buckets && a.names == b.names }

    struct Point: Identifiable {
        var id: String { "\(name)-\(date.timeIntervalSince1970)" }
        let date: Date
        let name: String
        let value: Double
    }

    var body: some View {
        var sums: [String: Double] = [:]
        for b in buckets { for (k, v) in b.rates { sums[k, default: 0] += v } }
        let top = sums.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map(\.key)
        // 色は名前順で固定して割り当てる（順位が入れ替わっても色が変わらないように）
        let domain = Array(Set(top.map { names[$0] ?? "終了したプロセス" })).sorted() + ["その他"]
        var points: [Point] = []
        for b in buckets {
            var other = 0.0
            for (k, v) in b.rates where !top.contains(k) { other += v }
            for k in top { points.append(Point(date: b.date, name: names[k] ?? "終了したプロセス", value: b.rates[k] ?? 0)) }
            points.append(Point(date: b.date, name: "その他", value: other))
        }
        return Chart(points) { p in
            AreaMark(x: .value("時刻", p.date), y: .value("bytes/s", p.value), stacking: .standard)
                .foregroundStyle(by: .value("アプリ", p.name))
        }
        .chartForegroundStyleScale(domain: domain)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Rate.text(d)) } }
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(position: .trailing, alignment: .top)
        .transaction { $0.animation = nil }
        .overlay {
            if buckets.count < 2 {
                Text("通信量の推移を集めています…（10秒ごとに更新）").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProcessInspector: View {
    @Environment(AppModel.self) private var model
    let row: TrafficRow?
    @State private var names: [String: String] = [:]
    @State private var showListening = false

    var body: some View {
        if let row {
            let pm = model.processes
            let conns = pm.connections(for: row)
                .filter { showListening || !$0.isListening }
                // 累計の多い順（瞬間値だと2秒ごとに並びが変わる）。同じなら ID で固定
                .sorted { ($0.rxTotal + $0.txTotal, $1.id) > ($1.rxTotal + $1.txTotal, $0.id) }
            let history = pm.history.map { ($0.date, $0.rates[row.id] ?? 0) }

            List {
                Section {
                    HStack(spacing: 12) {
                        if let icon = pm.icon(for: row) {
                            Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                        } else {
                            Image(systemName: "gearshape.2").font(.largeTitle).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text(row.name).font(.headline)
                            Text("PID " + row.pids.map(String.init).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Chart(history, id: \.0) { d, v in
                        AreaMark(x: .value("時刻", d), y: .value("bytes/s", v))
                            .foregroundStyle(.tint.opacity(0.3))
                        LineMark(x: .value("時刻", d), y: .value("bytes/s", v))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine()
                            AxisValueLabel { if let d = v.as(Double.self) { Text(Rate.text(d)) } }
                        }
                    }
                    .frame(height: 90)
                    .transaction { $0.animation = nil }
                    LabeledContent("いま", value: "↓\(Rate.text(row.rxRate))  ↑\(Rate.text(row.txRate))")
                    LabeledContent("累計", value: "↓\(Rate.bytes(row.rxTotal))  ↑\(Rate.bytes(row.txTotal))")
                    LabeledContent("TCP 再送", value: Rate.bytes(row.retransmitTotal))
                    if let path = row.bundlePath {
                        LabeledContent("場所") { Text(path).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                    }
                }
                Section {
                    ForEach(conns) { c in
                        ConnectionRow(conn: c, name: names[c.remoteHost])
                    }
                    if conns.isEmpty {
                        Text("接続はありません").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("接続（\(conns.count)）")
                        Spacer()
                        Toggle("待ち受けも表示", isOn: $showListening).toggleStyle(.checkbox).font(.caption)
                    }
                }
            }
            .task(id: conns.map(\.remoteHost).filter { RemoteScope($0) == .internet }.sorted().joined()) {
                // 選択中のアプリの接続先だけ逆引きする
                for host in Set(conns.map(\.remoteHost)) where RemoteScope(host) == .internet && names[host] == nil {
                    if let n = await HostNameCache.shared.resolve(host) { names[host] = n }
                    if Task.isCancelled { return }
                }
            }
        } else {
            ContentUnavailableView("アプリを選択", systemImage: "cursorarrow.click.2",
                                   description: Text("一覧から選ぶと、通信量の推移と接続先の一覧を表示します。"))
        }
    }
}

private struct ConnectionRow: View {
    let conn: NetConnection
    let name: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(conn.proto)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .background(conn.proto == "TCP" ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15), in: .capsule)
                Text(conn.isListening ? "待ち受け :\(conn.localPort)" : (name ?? conn.remoteHost))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !conn.isListening { Text(":\(conn.remotePort)").foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if conn.rxRate + conn.txRate > 0 {
                    Text("↓\(Rate.text(conn.rxRate)) ↑\(Rate.text(conn.txRate))").font(.caption).monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                if name != nil { Text(conn.remoteHost).lineLimit(1).truncationMode(.middle) }
                Text(conn.remoteScope.label)
                if !conn.interface.isEmpty { Text(conn.interface) }
                if !conn.state.isEmpty { Text(conn.state) }
                if let rtt = conn.rttMs { Text("RTT \(Fmt.ms(rtt)) ms") }
                if conn.retransmitTotal > 0 { Text("再送 \(Rate.bytes(conn.retransmitTotal))").foregroundStyle(.orange) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .textSelection(.enabled)
    }
}
