import Charts
import SwiftUI

struct LoadTestView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var lt = model.loadTest
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card("Latency Under Load (Bufferbloat)", systemImage: "chart.line.uptrend.xyaxis",
                     subtitle: String(localized: "Deliberately saturates your connection and measures how far latency rises (bufferbloat). It directly checks why calls and games freeze during large downloads.")) {
                    HStack(alignment: .center, spacing: 20) {
                        Picker("Direction", selection: $lt.mode) {
                            ForEach(LoadTest.Mode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(lt.isRunning)
                        Stepper("\(lt.duration) s per phase", value: $lt.duration, in: 10...60, step: 5)
                            .fixedSize()
                            .disabled(lt.isRunning)
                        Stepper("Streams: \(lt.streams)", value: $lt.streams, in: 1...16)
                            .fixedSize()
                            .disabled(lt.isRunning)
                        Spacer()
                        if lt.isRunning {
                            Button(role: .cancel) { lt.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                        } else {
                            Button {
                                lt.start(env: model.monitor.env)
                            } label: {
                                Label("Start Test (about \(lt.totalSeconds + 2) s)", systemImage: "play.fill")
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                        }
                    }

                    Label("Others on the same connection will also be slowed for a few tens of seconds. Pause large downloads while testing.", systemImage: "info.circle")
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
        .navigationTitle("Load Test")
    }

    private func liveCard(_ lt: LoadTest) -> some View {
        Card("Live Measurement", systemImage: "waveform.path.ecg",
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
                LineMark(x: .value("Elapsed (s)", p.elapsed), y: .value("ms", max(0.1, p.ms)), series: .value("Target", p.series))
                    .foregroundStyle(by: .value("Target", p.series))
            }
            .chartForegroundStyleScale([SeriesName.router: SeriesColor.router, SeriesName.internet: SeriesColor.inet4])
            .chartYScale(type: .log)
            .chartYAxisLabel("ms")
            .chartXAxisLabel("Elapsed (s)")
            .frame(height: 220)
        }
    }

    private func resultCard(_ r: LoadTestRecord) -> some View {
        let idle = r.phases["idle"]
        return Card("Verdict", systemImage: "checkmark.seal", subtitle: String(localized: "\(r.date.formatted(date: .abbreviated, time: .shortened)) · Target \(r.target) · Router \(r.gw)")) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(["down", "up"], id: \.self) { key in
                    if let v = r.verdict?[key] {
                        let g = LoadTest.grade(idleP50: idle?.inet?.p50, loadedP95: v.inet_p95)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(key == "down" ? "Download Saturated" : "Upload Saturated")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(v.grade)
                                    .font(.system(size: 52, weight: .bold, design: .rounded))
                                    .foregroundStyle(g.level.tint)
                                Text(g.note).font(.callout)
                            }
                            Text(String(localized: "Internet p95 \(Fmt.ms(v.inet_p95)) ms (idle \(Fmt.ms(idle?.inet?.p50)) ms)\nRouter p95 \(Fmt.ms(v.gw_p95)) ms (idle \(Fmt.ms(idle?.gw?.p50)) ms)"))
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
            DisclosureGroup("Details by Phase") {
                PingStatsGrid(rows: ["idle", "down", "rest1", "up"].flatMap { key -> [(String, PingStats)] in
                    guard let ph = r.phases[key] else { return [] }
                    let name = ["idle": String(localized: "Idle"), "down": String(localized: "Download Load"), "rest1": String(localized: "Recovery"), "up": String(localized: "Upload Load")][key] ?? key
                    let thr = ph.rx_mbps.map { " ↓\($0) ↑\(ph.tx_mbps ?? 0) Mbps" } ?? ""
                    return [(String(localized: "\(name) Router"), ph.gw ?? .empty), (String(localized: "\(name) Internet\(thr)"), ph.inet ?? .empty)]
                })
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func summary(_ r: LoadTestRecord) -> some View {
        switch r.worst_grade {
        case "D", "F":
            ObservationRow(level: .crit, text: String(localized: "On this connection, as soon as someone starts a large transfer, other traffic is delayed by hundreds of milliseconds to several seconds."),
                           detail: String(localized: "Enabling QoS / SQM (fq_codel or cake) on your router, or limiting upload bandwidth to about 90% of the measured speed, will help."))
        case "B", "C":
            ObservationRow(level: .warn, text: String(localized: "There is mild to moderate bufferbloat. Expect symptoms at peak times."))
        default:
            ObservationRow(level: .good, text: String(localized: "Latency barely increases under load."),
                           detail: String(localized: "Any latency problems likely come from the Wi-Fi segment, disconnects, or ISP congestion at certain times. Use continuous monitoring and Wi-Fi Events to narrow it down."))
        }
    }
}
