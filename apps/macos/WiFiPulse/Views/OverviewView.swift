import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeroCard()
                PathCard()
                TilesGrid()
                Card("Responsiveness (Last 2 Minutes)", systemImage: "waveform.path.ecg", subtitle: String(localized: "Lines show the maximum for each second, so spikes are visible as they happen. Gray shading marks time left out of the score (speed tests, load tests, device scans).")) {
                    RecentLatencyChart(seconds: 120)
                        .frame(height: 180)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.selection = .speed
                    Task { await model.speedTest.run(env: model.monitor.env) }
                } label: {
                    Label("Measure Speed", systemImage: "speedometer")
                }
                .disabled(model.speedTest.isRunning)
                .help("Measure speed and responsiveness with networkQuality")
            }
        }
    }
}

private struct HeroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.monitor.live
        let band = Analysis.timeBand(s.date == .distantPast ? Date() : s.date)
        Card {
            HStack(alignment: .center, spacing: 28) {
                ScoreRing(score: s.score, level: s.level, progress: s.pause?.progress)
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 12) {
                    Text(s.verdict)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(s.pause?.detail ?? Analysis.sentence(s.w60, short: s.w30, link: s.link))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        LevelBadge(text: s.bottleneck.tag, level: s.bottleneck.level)
                        Text(s.bottleneck.text).font(.callout)
                    }
                    Label {
                        Text("\(Text("It’s \(band.name) now. ").bold())\(band.note)")
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct PathCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.monitor.live
        PathDiagram(window: s.w60, highlight: s.bottleneck.segment)
    }
}

private struct TilesGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let m = model.monitor
        let s = m.live
        let link = s.link
        let (stab, stabLevel) = Analysis.stability(s.w60)
        let lastDNS = m.dns.last?.ms
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            MetricTile(title: "Signal", systemImage: "wifi",
                       value: link?.strengthWord.sentenceCased ?? "—",
                       caption: link.map { "\($0.rssi) dBm · SNR \($0.snr) dB · \($0.bandLabel)" } ?? String(localized: "Not connected to Wi-Fi"),
                       level: Level.rssi(link?.rssi))
            MetricTile(title: "To the Internet", systemImage: "globe.asia.australia",
                       value: Fmt.ms(s.w30.v4.p50), unit: "ms",
                       caption: "p95 \(Fmt.ms(s.w30.v4.p95)) ms · IPv6 \(Fmt.ms(s.w60.v6.p50)) ms",
                       level: Level.internet(s.w30.v4.p95))
            MetricTile(title: "To the Router", systemImage: "wifi.router",
                       value: Fmt.ms(s.w30.gw.p50), unit: "ms",
                       // テザリングなどでルーターが ping に答えないときは、ロスではないことを書く
                       caption: s.gatewaySilent
                           ? String(localized: "Doesn’t answer ping · \(m.env.gateway)")
                           : "p95 \(Fmt.ms(s.w30.gw.p95)) ms · \(m.env.gateway.isEmpty ? "—" : m.env.gateway)",
                       level: s.gatewaySilent ? .none : Level.gateway(s.w30.gw.p95))
            MetricTile(title: "Stability", systemImage: "waveform",
                       value: stab,
                       caption: String(localized: "Loss \(Fmt.pct(s.w60.worstLoss))% · Jitter \(Fmt.ms(s.w60.v4.jitter)) ms"),
                       level: stabLevel)
            MetricTile(title: "Current Traffic", systemImage: "arrow.up.arrow.down",
                       value: "↓\(Fmt.mbps(s.rx))", unit: "Mbps",
                       caption: "↑ \(Fmt.mbps(s.tx)) Mbps" + (s.rx < 5e5 && s.tx < 5e5 ? String(localized: " (mostly idle)") : String(localized: " (active)")))
            MetricTile(title: "DNS Response", systemImage: "character.book.closed",
                       value: Fmt.ms(lastDNS), unit: "ms",
                       caption: String(localized: "Queries your router’s DNS every 10 seconds"),
                       level: Level.dns(lastDNS))
        }
    }
}

/// Mac ─ Wi-Fi区間 ─ ルーター ─ 回線区間 ─ インターネット
/// ルーター宛てとインターネット宛てを同時に測っているので、どちらの区間が遅いかが一目で分かる。
struct PathDiagram: View {
    let window: WindowStats
    let highlight: Analysis.Segment?

    var body: some View {
        Card("Where the Delay Is", systemImage: "point.3.connected.trianglepath.dotted",
             subtitle: String(localized: "Pings to the router and to the Internet run at the same time and are split into per-segment latency (median of the last 60 seconds)")) {
            HStack(spacing: 0) {
                node("This Mac", "laptopcomputer")
                segment("Wi-Fi segment", ms: window.gw.p50,
                        level: max(Level.gateway(window.gw.p95), Level.loss(window.gw.loss)),
                        emphasized: highlight == .wifi)
                node("Router", "wifi.router")
                segment("Internet line", ms: window.wanP50,
                        level: max(Level.internet(window.v4.p95), Level.loss(window.v4.loss)),
                        emphasized: highlight == .wan)
                node("Internet", "globe.asia.australia")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func node(_ title: LocalizedStringKey, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(.background, in: .circle)
                .overlay(Circle().strokeBorder(.separator))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func segment(_ title: LocalizedStringKey, ms: Double?, level: Level, emphasized: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(Fmt.ms(ms)).font(.title3.weight(.semibold)).monospacedDigit()
                Text("ms").font(.caption).foregroundStyle(.secondary)
            }
            Capsule()
                .fill(level == .none ? AnyShapeStyle(.quaternary) : AnyShapeStyle(level.tint))
                .frame(height: emphasized ? 8 : 5)
            HStack(spacing: 4) {
                if emphasized { Image(systemName: level.symbol).foregroundStyle(level.tint) }
                Text(title)
            }
            .font(.caption.weight(emphasized ? .semibold : .regular))
            .foregroundStyle(emphasized ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recent latency chart

struct LatencySample: Identifiable, Equatable {
    var id: Double { date.timeIntervalSince1970 }
    let date: Date
    let router: Double?
    let internet: Double?
    let lost: Bool
    /// 判定から外した秒（帯で示す）
    var excluded = false
}

/// 直近 N 秒の「各秒の最大値」。履歴は `revision` を読んだときだけ参照する。
struct RecentLatencyChart: View {
    @Environment(AppModel.self) private var model
    let seconds: Int
    var compact = false

    var body: some View {
        let m = model.monitor
        let _ = m.revision
        let samples = m.recent(seconds).map {
            LatencySample(date: $0.date, router: $0.gw.rtts.max(), internet: $0.v4.rtts.max(), lost: $0.gw.lost + $0.v4.lost > 0, excluded: $0.excluded != nil)
        }
        LatencyLineChart(samples: samples, compact: compact)
            .equatable()
    }
}

struct LatencyLineChart: View, Equatable {
    let samples: [LatencySample]
    var compact = false

    /// 対数軸の範囲。自動だと 1〜100 のような切りのよい範囲に広がり、小さいグラフでは線が下に寄って上が空くので、
    /// 値の範囲に少し余白を足した分だけにする
    private var yDomain: ClosedRange<Double> {
        let values = samples.flatMap { [$0.router, $0.internet] }.compactMap { $0 }.map { max(0.1, $0) }
        guard let lo = values.min(), let hi = values.max() else { return 1...100 }
        return (lo / 1.3)...max(hi * 1.3, lo / 1.3 * 2)
    }

    var body: some View {
        Chart {
            ForEach(LatencySeries.spans(samples.filter(\.excluded).map(\.date)), id: \.lowerBound) { r in
                // ライト・ダークのどちらでも背景からわずかに浮く濃さにする
                RectangleMark(xStart: .value("Time", r.lowerBound), xEnd: .value("Time", r.upperBound))
                    .foregroundStyle(Color.primary.opacity(0.08))
            }
            ForEach(samples) { s in
                if let v = s.router {
                    LineMark(x: .value("Time", s.date), y: .value("ms", max(0.1, v)), series: .value("Target", SeriesName.router))
                        .foregroundStyle(by: .value("Target", SeriesName.router))
                }
                if let v = s.internet {
                    LineMark(x: .value("Time", s.date), y: .value("ms", max(0.1, v)), series: .value("Target", SeriesName.internet))
                        .foregroundStyle(by: .value("Target", SeriesName.internet))
                }
                if s.lost {
                    RuleMark(x: .value("Time", s.date))
                        .foregroundStyle(.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartForegroundStyleScale([SeriesName.router: SeriesColor.router, SeriesName.internet: SeriesColor.inet4])
        .chartYScale(domain: yDomain, type: .log)
        // 空の文字列でも軸ラベルの1行分が上に空くので、小さいグラフでは付けない
        .chartYAxisLabel {
            if !compact { Text("ms") }
        }
        .chartYAxis(compact ? .hidden : .automatic)
        .chartLegend(compact ? .hidden : .visible)
        .chartLegend(position: .top, alignment: .trailing)
        .transaction { $0.animation = nil }
    }
}
