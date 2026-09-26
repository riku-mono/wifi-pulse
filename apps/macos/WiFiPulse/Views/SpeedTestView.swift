import Charts
import SwiftUI

struct SpeedTestView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let st = model.speedTest
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card("速度と応答性", systemImage: "speedometer",
                     subtitle: "macOS 標準の networkQuality で測ります。回線を一時的に埋めるので、同居人がいれば一声かけてから。") {
                    runButton
                } content: {
                    switch st.state {
                    case .running(let started):
                        HStack(spacing: 14) {
                            ProgressView().controlSize(.large)
                            VStack(alignment: .leading) {
                                Text("測定しています…").font(.headline)
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
                        ContentUnavailableView("まだ測っていません", systemImage: "speedometer",
                                               description: Text("「速度を測る」を押すと、下り・上りの速度と、回線が埋まったときの応答性（RPM）を測ります。"))
                    }
                }

                if st.history.count >= 2 {
                    Card("これまでの結果", systemImage: "clock.arrow.circlepath", subtitle: "時間帯によって大きく違うなら、回線側の混雑が疑われます") {
                        Chart {
                            ForEach(st.history) { r in
                                LineMark(x: .value("日時", r.date), y: .value("Mbps", r.dl), series: .value("方向", "下り"))
                                    .foregroundStyle(by: .value("方向", "下り"))
                                    .symbol(.circle)
                                LineMark(x: .value("日時", r.date), y: .value("Mbps", r.ul), series: .value("方向", "上り"))
                                    .foregroundStyle(by: .value("方向", "上り"))
                                    .symbol(.square)
                            }
                        }
                        .chartForegroundStyleScale(["下り": SeriesColor.rx, "上り": SeriesColor.tx])
                        .chartYAxisLabel("Mbps")
                        .frame(height: 200)

                        Table(st.history.reversed()) {
                            TableColumn("日時") { Text(Fmt.stamp($0.date)) }
                            TableColumn("下り") { Text("\(String(format: "%.1f", $0.dl)) Mbps").monospacedDigit() }
                            TableColumn("上り") { Text("\(String(format: "%.1f", $0.ul)) Mbps").monospacedDigit() }
                            TableColumn("応答性 ↓") { r in rpmText(r.dl_rpm) }
                            TableColumn("応答性 ↑") { r in rpmText(r.ul_rpm) }
                            TableColumn("無負荷RTT") { Text("\(Fmt.ms($0.base_rtt)) ms").monospacedDigit() }
                        }
                        .frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("速度測定")
    }

    private var runButton: some View {
        Button {
            Task { await model.speedTest.run(interface: model.monitor.env.interface) }
        } label: {
            Label("速度を測る", systemImage: "play.fill")
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
                MetricTile(title: "下り", systemImage: "arrow.down.circle", value: String(format: "%.1f", r.dl), unit: "Mbps")
                MetricTile(title: "上り", systemImage: "arrow.up.circle", value: String(format: "%.1f", r.ul), unit: "Mbps")
                MetricTile(title: "応答性（下り負荷時）", systemImage: "hare", value: r.dl_rpm.map { "\(Int($0))" } ?? "—", unit: "RPM",
                           caption: rpmWord(r.dl_rpm), level: Level.rpm(r.dl_rpm))
                MetricTile(title: "応答性（上り負荷時）", systemImage: "hare", value: r.ul_rpm.map { "\(Int($0))" } ?? "—", unit: "RPM",
                           caption: rpmWord(r.ul_rpm), level: Level.rpm(r.ul_rpm))
                MetricTile(title: "無負荷時の往復", systemImage: "arrow.left.arrow.right", value: Fmt.ms(r.base_rtt), unit: "ms")
            }
            Text("\(r.date.formatted(date: .abbreviated, time: .shortened)) に測定 · 応答性（RPM）は「回線が埋まっているときに1分あたり何往復できるか」。Apple の目安は 良い=800以上、普通=300〜800、悪い=300未満。300未満ならバッファブロートを疑い、「負荷試験」で区間を切り分けてください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rpmWord(_ v: Double?) -> String {
        switch Level.rpm(v) {
        case .good: "良い"
        case .warn: "普通"
        case .crit: "悪い — 回線が混むと通話が乱れます"
        case .none: "—"
        }
    }
}
