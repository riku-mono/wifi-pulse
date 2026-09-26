import Charts
import SwiftUI

struct ReportView: View {
    @Environment(AppModel.self) private var model
    @State private var records = RecordSet()
    @State private var filter: DayFilter = .all
    @State private var hours: Int? = nil
    /// nil はいまのネットワーク（切り替わったら追従する）
    @State private var scope: NetworkFilter?
    @State private var copied = false

    var body: some View {
        let rows = Report.hourly(records, filter: filter)
        let findings = Report.findings(records, hourly: Report.hourly(records, filter: .all))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                coverage
                Card("Trends by Hour", systemImage: "calendar.day.timeline.left",
                     subtitle: String(localized: "Medians of the per-minute records, grouped by hour. If only certain hours are bad, suspect congestion at your ISP.")) {
                    Picker("Days", selection: $filter) {
                        ForEach(DayFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } content: {
                    if records.minutes.isEmpty {
                        ContentUnavailableView("No Records Yet", systemImage: "hourglass",
                                               description: Text("Records accumulate every minute while the app is running. Keep it running for half a day to a full day, including the times problems occur."))
                            .frame(minHeight: 160)
                    } else {
                        Chart(rows.filter { $0.minutes > 0 }) { h in
                            if let v = h.v4 {
                                BarMark(x: .value("Hour", h.hour), y: .value("ms", v), width: .ratio(0.7))
                                    .foregroundStyle(by: .value("Series", SeriesName.internetMedian))
                            }
                            if let g = h.gw {
                                PointMark(x: .value("Hour", h.hour), y: .value("ms", g))
                                    .foregroundStyle(by: .value("Series", SeriesName.routerMedian))
                                    .symbolSize(40)
                            }
                            if let p = h.v495 {
                                RuleMark(x: .value("Hour", h.hour), yStart: .value("Median", h.v4 ?? p), yEnd: .value("p95", p))
                                    .foregroundStyle(SeriesColor.inet4.opacity(0.35))
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        .chartForegroundStyleScale([SeriesName.internetMedian: SeriesColor.inet4, SeriesName.routerMedian: SeriesColor.router])
                        .chartXScale(domain: 0...23)
                        .chartXAxis { AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) { v in
                            AxisGridLine(); AxisValueLabel { if let h = v.as(Int.self) { Text("\(h):00") } }
                        } }
                        .chartYAxisLabel("ms")
                        .frame(height: 220)

                        Table(rows.filter { $0.minutes > 0 }) {
                            TableColumn("Time") { Text("\($0.hour):00–") }
                            TableColumn("Records") { Text("\($0.minutes) min").monospacedDigit() }
                            TableColumn("Internet Latency") { Text("\(Fmt.ms($0.v4)) ms").monospacedDigit() }
                            TableColumn("p95") { Text("\(Fmt.ms($0.v495)) ms").monospacedDigit() }
                            TableColumn("Loss") { h in Text("\(Fmt.pct(h.loss))%").monospacedDigit().foregroundStyle(Level.loss(h.loss).tint) }
                            TableColumn("Router") { Text("\(Fmt.ms($0.gw)) ms").monospacedDigit() }
                            TableColumn("RSSI") { Text($0.rssi.map { "\(Int($0)) dBm" } ?? "—").monospacedDigit() }
                            TableColumn("Speed") { h in Text(h.dl.map { String(format: "%.0f Mbps", $0) } ?? "—").monospacedDigit() }
                        }
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                    }
                }

                Card("Findings (Most Severe First)", systemImage: "stethoscope",
                     subtitle: String(localized: "Issues found in the recorded measurements, most severe first")) {
                    if findings.isEmpty {
                        ObservationRow(level: .good, text: String(localized: "No notable problems were found."),
                                       detail: String(localized: "There may simply be no data from the times problems occur. Keep monitoring running and note when problems happen so you can compare."))
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
        .navigationTitle("Trends & Report")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                networkPicker
                Picker("Scope", selection: $hours) {
                    Text("All Records").tag(Int?.none)
                    Text("Last 24 Hours").tag(Int?.some(24))
                    Text("Last 7 Days").tag(Int?.some(24 * 7))
                }
                .fixedSize()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Report.markdown(records, findings: findings, network: scopeName), forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy as Markdown", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy in Markdown format to paste into other apps")
                Button {
                    try? FileManager.default.createDirectory(at: DataStore.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(DataStore.folder)
                } label: {
                    Label("Data Folder", systemImage: "folder")
                }
            }
        }
        .task(id: "\(hours ?? -1)-\(String(describing: effectiveScope))-\(model.monitor.minuteRevision)-\(model.speedTest.history.count)-\(model.loadTest.history.count)") {
            let h = hours, n = effectiveScope
            records = await Task.detached(priority: .utility) { RecordSet.load(hours: h, network: n) }.value
        }
        .onChange(of: records.minutes.count) { copied = false }
    }

    private var effectiveScope: NetworkFilter { scope ?? NetworkFilter(model.monitor.network) }

    private func name(_ id: String) -> String {
        model.monitor.networks[id]?.displayName ?? String(localized: "Unknown Network")
    }

    private var scopeName: String {
        switch effectiveScope {
        case .all: String(localized: "All Networks")
        case .unknown: String(localized: "Network Not Recorded")
        case .network(let id): name(id)
        }
    }

    /// 既定はいまのネットワーク。ほかの場所で計測した記録もここから選んで見られる
    private var networkPicker: some View {
        let current = model.monitor.network
        let others = model.monitor.networks.values
            .filter { $0.id != current }
            .sorted { $0.first > $1.first }
        return Picker("Network", selection: $scope) {
            Text(current.map { String(localized: "This Network (\(name($0)))") } ?? String(localized: "This Network"))
                .tag(NetworkFilter?.none)
            if !others.isEmpty {
                Divider()
                ForEach(others) { Text($0.displayName).tag(NetworkFilter?.some(.network($0.id))) }
            }
            Divider()
            Text("Network Not Recorded").tag(NetworkFilter?.some(.unknown))
            Text("All Networks").tag(NetworkFilter?.some(.all))
        }
        .fixedSize()
        .help("Records are kept separately for each network (router). Records made before this was tracked are under “Network Not Recorded”.")
    }

    private var coverage: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            MetricTile(title: "Continuous Monitoring", systemImage: "clock", value: String(format: "%.1f", Double(records.minutes.count) / 60), unit: String(localized: "h"),
                       caption: records.minutes.first.map { String(localized: "Since \(Fmt.stamp($0.date))") } ?? String(localized: "No records"),
                       level: records.minutes.count >= 120 ? .good : records.minutes.isEmpty ? .none : .warn)
            MetricTile(title: "Speed Test", systemImage: "speedometer", value: "\(records.speed.count)", unit: String(localized: "unit.runs", defaultValue: "", comment: "回数の単位。英語では付けない"))
            MetricTile(title: "Load Test", systemImage: "chart.line.uptrend.xyaxis", value: "\(records.loads.count)", unit: String(localized: "unit.runs", defaultValue: "", comment: "回数の単位。英語では付けない"),
                       caption: records.loads.isEmpty ? String(localized: "Tests delay under congestion") : records.loads.last?.worst_grade.map { String(localized: "Latest grade: \($0)") })
        }
    }
}
