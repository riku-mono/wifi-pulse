import Charts
import SwiftUI

struct EventsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ev = model.events
        Group {
            if let r = ev.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(r)
                        timeline(r)
                        HStack(alignment: .top, spacing: 16) {
                            requesters(r)
                            awdl(r)
                        }
                        details(r)
                    }
                    .padding(24)
                }
            } else if ev.isLoading {
                ProgressView("統合ログを読んでいます…（数十秒かかることがあります）")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Wi-Fi イベントを読み込む", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("macOS の統合ログから、切断・ローミング・スキャン・レーダー検出（DFS）・AWDL など、遅延スパイクの原因になりうる出来事を抜き出します。症状が出た直後に読むのが効果的です。")
                } actions: {
                    Button("読み込む") { Task { await ev.load() } }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle("Wi-Fi イベント")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("期間", selection: $ev.span) {
                    ForEach(WiFiEvents.Span.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await ev.load() }
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                }
                .disabled(ev.isLoading)
            }
        }
    }

    private func summary(_ r: WiFiEvents.Report) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(WiFiEvents.Category.allCases) { c in
                let n = r.counts[c] ?? 0
                MetricTile(title: LocalizedStringKey(c.title), systemImage: c.symbol, value: "\(n)", unit: String(localized: "件"),
                           caption: c == .scan ? String(localized: "うち live scan \(r.liveScans) 件") : nil,
                           level: level(c, n))
            }
        }
    }

    private func level(_ c: WiFiEvents.Category, _ n: Int) -> Level {
        switch c {
        case .disconnect, .dfs: n > 0 ? .crit : .good
        case .roam: n > 10 ? .warn : .none
        case .btcoex: n > 20 ? .warn : .none
        default: .none
        }
    }

    private func timeline(_ r: WiFiEvents.Report) -> some View {
        let shown: Set<WiFiEvents.Category> = [.disconnect, .roam, .scan, .dfs]
        return Card("10分ごとの件数", systemImage: "chart.bar.xaxis",
                    subtitle: String(localized: "直近\(ev_label(r.span)) · \(r.lineCount) 行のログを解析 · \(Fmt.time(r.generated)) 取得")) {
            Chart(r.buckets.filter { shown.contains($0.category) }) { b in
                BarMark(x: .value("時刻", b.start, unit: .minute), y: .value("件数", b.count), width: .ratio(0.85))
                    .foregroundStyle(by: .value("種類", b.category.title))
            }
            .chartForegroundStyleScale([
                WiFiEvents.Category.disconnect.title: Color.red,
                WiFiEvents.Category.dfs.title: Color.orange,
                WiFiEvents.Category.roam.title: Color.purple,
                WiFiEvents.Category.scan.title: Color.teal,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 200)
        }
    }

    private func ev_label(_ span: String) -> String {
        WiFiEvents.Span(rawValue: span)?.label ?? span
    }

    private func requesters(_ r: WiFiEvents.Report) -> some View {
        Card("誰がスキャンを要求したか", systemImage: "person.crop.circle.badge.questionmark") {
            if r.requesters.isEmpty {
                Text("スキャン要求は見つかりませんでした").foregroundStyle(.secondary)
            } else {
                let top = r.requesters.first?.count ?? 1
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(r.requesters, id: \.name) { item in
                        HStack {
                            Text(item.name).font(.callout.monospaced()).frame(width: 150, alignment: .leading)
                            GeometryReader { geo in
                                Capsule().fill(.teal.gradient)
                                    .frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(top)))
                            }
                            .frame(height: 8)
                            Text("\(item.count)").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Text("locationd = 位置情報サービス、sharingd = AirDrop の相手探索。自作の監視ツールや system_profiler も原因になります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func awdl(_ r: WiFiEvents.Report) -> some View {
        let up = r.awdlState.contains("UP") && r.awdlState.contains("RUNNING")
        return Card("AWDL の状態", systemImage: "airplayaudio") {
            LevelBadge(text: up ? String(localized: "動作中") : String(localized: "停止中"), level: up ? .warn : .good)
            Text(WiFiEvents.Category.awdl.explanation).font(.callout)
            Text("切り分けたいときは、通話中にターミナルで一時的に止めます（AirDrop・Sidecar・Handoff が止まります。再起動でも戻ります）:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("sudo ifconfig awdl0 down\nsudo ifconfig awdl0 up")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: .rect(cornerRadius: 8))
        }
    }

    private func details(_ r: WiFiEvents.Report) -> some View {
        Card("種類ごとの説明とログ", systemImage: "text.magnifyingglass") {
            ForEach(WiFiEvents.Category.allCases) { c in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(c.explanation).font(.callout)
                        if let lines = r.samples[c], !lines.isEmpty {
                            ScrollView(.horizontal) {
                                Text(lines.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .padding(8)
                            }
                            .background(.background, in: .rect(cornerRadius: 8))
                        }
                    }
                    .padding(.vertical, 6)
                } label: {
                    Label("\(c.title)（\(r.counts[c] ?? 0)件）", systemImage: c.symbol)
                }
            }
        }
    }
}
