import Charts
import SwiftUI

struct SpeedTestView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let st = model.speedTest
        let network = model.monitor.network, networks = model.monitor.networks
        let history = st.history.filter { $0.net != nil && networks.same($0.net, network) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card("Speed and Responsiveness", systemImage: "speedometer",
                     subtitle: String(localized: "Uses macOS’s built-in networkQuality. It briefly saturates your connection, so let others on your network know first.")) {
                    runButton
                } content: {
                    switch st.state {
                    case .running(let started):
                        HStack(spacing: 14) {
                            ProgressView().controlSize(.large)
                            VStack(alignment: .leading) {
                                Text("Measuring…").font(.headline)
                                Text(timerInterval: started...started.addingTimeInterval(3600), countsDown: false)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    case .failed(let msg):
                        ObservationRow(level: .crit, text: msg)
                    case .idle:
                        EmptyView()
                    }
                    if let r = st.latest, !st.isRunning {
                        result(r)
                    } else if st.latest == nil, !st.isRunning {
                        ContentUnavailableView("No Measurements Yet", systemImage: "speedometer",
                                               description: Text("Click Measure Speed to test download and upload speed, and responsiveness (RPM) while the connection is saturated."))
                    }
                }

                if history.count >= 2 {
                    Card("History", systemImage: "clock.arrow.circlepath", subtitle: String(localized: "Results on this network. Large differences by time of day suggest congestion at your ISP")) {
                        Chart {
                            ForEach(history) { r in
                                LineMark(x: .value("Date", r.date), y: .value("Mbps", r.dl), series: .value("Direction", SeriesName.download))
                                    .foregroundStyle(by: .value("Direction", SeriesName.download))
                                    .symbol(.circle)
                                LineMark(x: .value("Date", r.date), y: .value("Mbps", r.ul), series: .value("Direction", SeriesName.upload))
                                    .foregroundStyle(by: .value("Direction", SeriesName.upload))
                                    .symbol(.square)
                            }
                        }
                        .chartForegroundStyleScale([SeriesName.download: SeriesColor.rx, SeriesName.upload: SeriesColor.tx])
                        .chartYAxisLabel("Mbps")
                        .frame(height: 200)

                        Table(history.reversed()) {
                            TableColumn("Date") { Text(Fmt.stamp($0.date)) }
                            TableColumn("Download") { Text("\(String(format: "%.1f", $0.dl)) Mbps").monospacedDigit() }
                            TableColumn("Upload") { Text("\(String(format: "%.1f", $0.ul)) Mbps").monospacedDigit() }
                            TableColumn("Responsiveness ↓") { r in rpmText(r.dl_rpm) }
                            TableColumn("Responsiveness ↑") { r in rpmText(r.ul_rpm) }
                            TableColumn("Idle RTT") { Text("\(Fmt.ms($0.base_rtt)) ms").monospacedDigit() }
                        }
                        .frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Speed Test")
    }

    private var runButton: some View {
        Button {
            Task { await model.speedTest.run(env: model.monitor.env) }
        } label: {
            Label("Measure Speed", systemImage: "play.fill")
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(model.speedTest.isRunning)
    }

    private func rpmText(_ v: Double?) -> some View {
        Text(v.map { "\(Int($0)) RPM" } ?? "—")
            .monospacedDigit()
            .foregroundStyle(Level.rpm(v).tint)
    }

    private func result(_ r: SpeedTestRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                MetricTile(title: "Download", systemImage: "arrow.down.circle", value: String(format: "%.1f", r.dl), unit: "Mbps")
                MetricTile(title: "Upload", systemImage: "arrow.up.circle", value: String(format: "%.1f", r.ul), unit: "Mbps")
                MetricTile(title: "Responsiveness (Download Load)", systemImage: "hare", value: r.dl_rpm.map { "\(Int($0))" } ?? "—", unit: "RPM",
                           caption: rpmWord(r.dl_rpm), level: Level.rpm(r.dl_rpm))
                MetricTile(title: "Responsiveness (Upload Load)", systemImage: "hare", value: r.ul_rpm.map { "\(Int($0))" } ?? "—", unit: "RPM",
                           caption: rpmWord(r.ul_rpm), level: Level.rpm(r.ul_rpm))
                MetricTile(title: "Idle Round Trip", systemImage: "arrow.left.arrow.right", value: Fmt.ms(r.base_rtt), unit: "ms")
            }
            Text("Measured \(r.date.formatted(date: .abbreviated, time: .shortened)) · Responsiveness (RPM) is how many round trips per minute the connection can make while it is saturated. Apple’s guide: good = 800 or more, fair = 300–800, poor = under 300. Under 300 suggests bufferbloat; use Load Test to find which segment is responsible.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rpmWord(_ v: Double?) -> String {
        switch Level.rpm(v) {
        case .good: String(localized: "Good")
        case .warn: String(localized: "fair")
        case .crit: String(localized: "Poor — calls break up when the connection is busy")
        case .none: "—"
        }
    }
}
