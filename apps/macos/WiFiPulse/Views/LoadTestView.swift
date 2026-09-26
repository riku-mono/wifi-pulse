import Charts
import SwiftUI

struct LoadTestView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var lt = model.loadTest
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card("負荷時の遅延（バッファブロート）", systemImage: "chart.line.uptrend.xyaxis",
                     subtitle: String(localized: "回線をわざと埋めて、そのとき遅延がどこまで跳ねるかを測ります（バッファブロート）。大きなダウンロード中に通話やゲームが止まる原因を直接確かめる試験です。")) {
                    HStack(alignment: .center, spacing: 20) {
                        Picker("方向", selection: $lt.mode) {
                            ForEach(LoadTest.Mode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(lt.isRunning)
                        Stepper("各フェーズ \(lt.duration) 秒", value: $lt.duration, in: 10...60, step: 5)
                            .fixedSize()
                            .disabled(lt.isRunning)
                        Stepper("並列 \(lt.streams) 本", value: $lt.streams, in: 1...16)
                            .fixedSize()
                            .disabled(lt.isRunning)
                        Spacer()
                        if lt.isRunning {
                            Button(role: .cancel) { lt.cancel() } label: { Label("中止", systemImage: "stop.fill") }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                        } else {
                            Button {
                                lt.start(env: model.monitor.env)
                            } label: {
                                Label("試験を始める（約\(lt.totalSeconds + 2)秒）", systemImage: "play.fill")
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                        }
                    }

                    Label("同じ回線を使っている人の通信も数十秒間遅くなります。測定中は大きなダウンロードを止めてください。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let e = lt.error { ObservationRow(level: .warn, text: e) }
                }

                if lt.isRunning || !lt.live.isEmpty {
                    liveCard(lt)
                }

                if let r = lt.result, !lt.isRunning {
                    resultCard(r)
                }
            }
            .padding(24)
        }
        .navigationTitle("負荷試験")
    }

    private func liveCard(_ lt: LoadTest) -> some View {
        Card("計測の様子", systemImage: "waveform.path.ecg",
             subtitle: lt.isRunning ? "↓\(Fmt.mbps(lt.liveThroughput.rx)) Mbps · ↑\(Fmt.mbps(lt.liveThroughput.tx)) Mbps" : nil) {
            HStack(spacing: 6) {
                ForEach(lt.plan) { p in
                    let active = lt.currentPhase == p.key
                    let doneIndex = lt.plan.firstIndex { $0.key == lt.currentPhase } ?? lt.plan.count
                    let done = (lt.plan.firstIndex(of: p) ?? 0) < doneIndex
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: done ? "checkmark.circle.fill" : p.load == .down ? "arrow.down.circle" : p.load == .up ? "arrow.up.circle" : "pause.circle")
                                .foregroundStyle(done ? AnyShapeStyle(.green) : active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            Text(p.title).font(.caption.weight(active ? .semibold : .regular))
                        }
                        ProgressView(value: active ? lt.phaseProgress : done ? 1 : 0)
                            .progressViewStyle(.linear)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Chart(lt.live) { p in
                LineMark(x: .value("経過秒", p.elapsed), y: .value("ms", max(0.1, p.ms)), series: .value("宛先", p.series))
                    .foregroundStyle(by: .value("宛先", p.series))
            }
            .chartForegroundStyleScale([SeriesName.router: SeriesColor.router, SeriesName.internet: SeriesColor.inet4])
            .chartYScale(type: .log)
            .chartYAxisLabel("ms")
            .chartXAxisLabel("経過秒")
            .frame(height: 220)
        }
    }

    private func resultCard(_ r: LoadTestRecord) -> some View {
        let idle = r.phases["idle"]
        return Card("判定", systemImage: "checkmark.seal", subtitle: String(localized: "\(r.date.formatted(date: .abbreviated, time: .shortened)) · 宛先 \(r.target) · ルーター \(r.gw)")) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(["down", "up"], id: \.self) { key in
                    if let v = r.verdict?[key] {
                        let g = LoadTest.grade(idleP50: idle?.inet?.p50, loadedP95: v.inet_p95)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(key == "down" ? "下りを埋めたとき" : "上りを埋めたとき")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(v.grade)
                                    .font(.system(size: 52, weight: .bold, design: .rounded))
                                    .foregroundStyle(g.level.tint)
                                Text(g.note).font(.callout)
                            }
                            Text(String(localized: "インターネット p95 \(Fmt.ms(v.inet_p95)) ms（無負荷 \(Fmt.ms(idle?.inet?.p50)) ms）\nルーター p95 \(Fmt.ms(v.gw_p95)) ms（無負荷 \(Fmt.ms(idle?.gw?.p50)) ms）"))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if let note = LoadTest.bottleneckNote(record: r, key: key) {
                                ObservationRow(level: g.level, text: note)
                                    .font(.callout)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            summary(r)
            DisclosureGroup("フェーズごとの詳細") {
                PingStatsGrid(rows: ["idle", "down", "rest1", "up"].flatMap { key -> [(String, PingStats)] in
                    guard let ph = r.phases[key] else { return [] }
                    let name = ["idle": String(localized: "無負荷"), "down": String(localized: "下り負荷"), "rest1": String(localized: "回復待ち"), "up": String(localized: "上り負荷")][key] ?? key
                    let thr = ph.rx_mbps.map { " ↓\($0) ↑\(ph.tx_mbps ?? 0) Mbps" } ?? ""
                    return [(String(localized: "\(name) ルーター"), ph.gw ?? .empty), (String(localized: "\(name) ネット\(thr)"), ph.inet ?? .empty)]
                })
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func summary(_ r: LoadTestRecord) -> some View {
        switch r.worst_grade {
        case "D", "F":
            ObservationRow(level: .crit, text: String(localized: "この回線は、誰かが大きな通信を始めた瞬間に、ほかの通信が数百ms〜数秒遅れる状態です。"),
                           detail: String(localized: "ルーターの QoS / SQM（fq_codel・cake）を有効にするか、上り帯域を実測値の90%程度に制限すると改善します。"))
        case "B", "C":
            ObservationRow(level: .warn, text: String(localized: "軽度〜中程度のバッファブロートがあります。ピーク時に症状が出るはずです。"))
        default:
            ObservationRow(level: .good, text: String(localized: "負荷をかけても遅延はほとんど増えません。"),
                           detail: String(localized: "遅延の原因があるとすれば、Wi-Fi 区間・切断・時間帯による回線の混雑です。常時計測と「Wi-Fi イベント」で切り分けてください。"))
        }
    }
}
