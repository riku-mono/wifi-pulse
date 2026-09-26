import Charts
import SwiftUI

struct ReportView: View {
    @Environment(AppModel.self) private var model
    @State private var records = RecordSet()
    @State private var filter: DayFilter = .all
    @State private var hours: Int? = nil
    @State private var copied = false

    var body: some View {
        let rows = Report.hourly(records, filter: filter)
        let findings = Report.findings(records, hourly: Report.hourly(records, filter: .all))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                coverage
                Card("時間帯ごとの傾向", systemImage: "calendar.day.timeline.left",
                     subtitle: "1分ごとの記録を時刻別にまとめた中央値。特定の時間帯だけ悪いなら回線側（ISPの輻輳）が疑われます。") {
                    Picker("曜日", selection: $filter) {
                        ForEach(DayFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } content: {
                    if records.minutes.isEmpty {
                        ContentUnavailableView("まだ記録がありません", systemImage: "hourglass",
                                               description: Text("アプリを起動している間、1分ごとに記録が溜まります。症状が出る時間帯を含めて、半日〜1日ほど動かし続けてください。"))
                            .frame(minHeight: 160)
                    } else {
                        Chart(rows.filter { $0.minutes > 0 }) { h in
                            if let v = h.v4 {
                                BarMark(x: .value("時", h.hour), y: .value("ms", v), width: .ratio(0.7))
                                    .foregroundStyle(by: .value("系列", "インターネット（中央値）"))
                            }
                            if let g = h.gw {
                                PointMark(x: .value("時", h.hour), y: .value("ms", g))
                                    .foregroundStyle(by: .value("系列", "ルーター（中央値）"))
                                    .symbolSize(40)
                            }
                            if let p = h.v495 {
                                RuleMark(x: .value("時", h.hour), yStart: .value("中央値", h.v4 ?? p), yEnd: .value("p95", p))
                                    .foregroundStyle(SeriesColor.inet4.opacity(0.35))
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        .chartForegroundStyleScale(["インターネット（中央値）": SeriesColor.inet4, "ルーター（中央値）": SeriesColor.router])
                        .chartXScale(domain: 0...23)
                        .chartXAxis { AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) { v in
                            AxisGridLine(); AxisValueLabel { if let h = v.as(Int.self) { Text("\(h)時") } }
                        } }
                        .chartYAxisLabel("ms")
                        .frame(height: 220)

                        Table(rows.filter { $0.minutes > 0 }) {
                            TableColumn("時刻") { Text("\($0.hour)時台") }
                            TableColumn("記録") { Text("\($0.minutes)分").monospacedDigit() }
                            TableColumn("ネット遅延") { Text("\(Fmt.ms($0.v4)) ms").monospacedDigit() }
                            TableColumn("p95") { Text("\(Fmt.ms($0.v495)) ms").monospacedDigit() }
                            TableColumn("ロス") { h in Text("\(Fmt.pct(h.loss))%").monospacedDigit().foregroundStyle(Level.loss(h.loss).tint) }
                            TableColumn("ルーター") { Text("\(Fmt.ms($0.gw)) ms").monospacedDigit() }
                            TableColumn("RSSI") { Text($0.rssi.map { "\(Int($0)) dBm" } ?? "—").monospacedDigit() }
                            TableColumn("速度") { h in Text(h.dl.map { String(format: "%.0f Mbps", $0) } ?? "—").monospacedDigit() }
                        }
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                    }
                }

                Card("所見（深刻な順）", systemImage: "stethoscope",
                     subtitle: "記録された計測結果から、気になる点を深刻な順に並べています") {
                    if findings.isEmpty {
                        ObservationRow(level: .good, text: "目立つ異常は見つかりませんでした。",
                                       detail: "ただし症状が出る時間帯のデータが無いだけの可能性があります。常時計測を続け、症状が出た時刻をメモしておくと突き合わせが最短です。")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(findings) { f in
                                ObservationRow(level: f.level, text: f.title,
                                               detail: f.detail + (f.advice.map { "\n→ \($0)" } ?? ""))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("時間帯とレポート")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("対象", selection: $hours) {
                    Text("すべての記録").tag(Int?.none)
                    Text("直近24時間").tag(Int?.some(24))
                    Text("直近7日").tag(Int?.some(24 * 7))
                }
                .fixedSize()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Report.markdown(records, findings: findings), forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "コピーしました" : "Markdown をコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("ほかのアプリに貼り付けられる Markdown 形式でコピーします")
                Button {
                    try? FileManager.default.createDirectory(at: DataStore.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(DataStore.folder)
                } label: {
                    Label("データフォルダ", systemImage: "folder")
                }
            }
        }
        .task(id: "\(hours ?? -1)-\(model.monitor.minuteRevision)-\(model.speedTest.history.count)-\(model.loadTest.history.count)") {
            let h = hours
            records = await Task.detached(priority: .utility) { RecordSet.load(hours: h) }.value
        }
        .onChange(of: records.minutes.count) { copied = false }
    }

    private var coverage: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            MetricTile(title: "常時計測", systemImage: "clock", value: String(format: "%.1f", Double(records.minutes.count) / 60), unit: "時間",
                       caption: records.minutes.first.map { "\(Fmt.stamp($0.date)) から" } ?? "記録なし",
                       level: records.minutes.count >= 120 ? .good : records.minutes.isEmpty ? .none : .warn)
            MetricTile(title: "速度測定", systemImage: "speedometer", value: "\(records.speed.count)", unit: "回")
            MetricTile(title: "負荷試験", systemImage: "chart.line.uptrend.xyaxis", value: "\(records.loads.count)", unit: "回",
                       caption: records.loads.isEmpty ? "混雑時の遅れを調べる検査" : records.loads.last?.worst_grade.map { "直近の判定 \($0)" })
        }
    }
}
