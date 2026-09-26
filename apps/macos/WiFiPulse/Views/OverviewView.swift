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
                Card("反応の速さ（直近2分）", systemImage: "waveform.path.ecg", subtitle: String(localized: "線はそれぞれの秒の最大値。跳ね上がりがそのまま見えます。")) {
                    RecentLatencyChart(seconds: 120)
                        .frame(height: 180)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("概要")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.selection = .speed
                    Task { await model.speedTest.run(interface: model.monitor.env.interface) }
                } label: {
                    Label("速度を測る", systemImage: "speedometer")
                }
                .disabled(model.speedTest.isRunning)
                .help("networkQuality で速度と応答性を測ります")
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
                ScoreRing(score: s.score, level: s.level)
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 12) {
                    Text(s.verdict)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(Analysis.sentence(s.w60, short: s.w30, link: s.link))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        LevelBadge(text: s.bottleneck.tag, level: s.bottleneck.level)
                        Text(s.bottleneck.text).font(.callout)
                    }
                    Label {
                        Text("\(Text("いまは「\(band.name)」。").bold())\(band.note)")
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
            MetricTile(title: "電波", systemImage: "wifi",
                       value: link?.strengthWord.sentenceCased ?? "—",
                       caption: link.map { "\($0.rssi) dBm · SNR \($0.snr) dB · \($0.bandLabel)" } ?? String(localized: "Wi-Fiに接続していません"),
                       level: Level.rssi(link?.rssi))
            MetricTile(title: "インターネットまで", systemImage: "globe.asia.australia",
                       value: Fmt.ms(s.w30.v4.p50), unit: "ms",
                       caption: "p95 \(Fmt.ms(s.w60.v4.p95)) ms · IPv6 \(Fmt.ms(s.w60.v6.p50)) ms",
                       level: Level.internet(s.w30.v4.p95))
            MetricTile(title: "ルーターまで", systemImage: "wifi.router",
                       value: Fmt.ms(s.w30.gw.p50), unit: "ms",
                       caption: "p95 \(Fmt.ms(s.w60.gw.p95)) ms · \(m.env.gateway.isEmpty ? "—" : m.env.gateway)",
                       level: Level.gateway(s.w30.gw.p95))
            MetricTile(title: "安定性", systemImage: "waveform",
                       value: stab,
                       caption: String(localized: "途切れ \(Fmt.pct(s.w60.worstLoss))% · 揺らぎ \(Fmt.ms(s.w60.v4.jitter)) ms"),
                       level: stabLevel)
            MetricTile(title: "いまの通信量", systemImage: "arrow.up.arrow.down",
                       value: "↓\(Fmt.mbps(s.rx))", unit: "Mbps",
                       caption: "↑ \(Fmt.mbps(s.tx)) Mbps" + (s.rx < 5e5 && s.tx < 5e5 ? String(localized: "（ほぼ待機中）") : String(localized: "（通信中）")))
            MetricTile(title: "DNS 応答", systemImage: "character.book.closed",
                       value: Fmt.ms(lastDNS), unit: "ms",
                       caption: String(localized: "ルーターのDNSへ10秒ごとに問い合わせ"),
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
        Card("どこで遅れているか", systemImage: "point.3.connected.trianglepath.dotted",
             subtitle: String(localized: "ルーター宛てとインターネット宛ての ping を同時に測り、区間ごとの遅延に分けています（直近60秒の中央値）")) {
            HStack(spacing: 0) {
                node("このMac", "laptopcomputer")
                segment("Wi-Fi区間", ms: window.gw.p50,
                        level: max(Level.gateway(window.gw.p95), Level.loss(window.gw.loss)),
                        emphasized: highlight == .wifi)
                node("ルーター", "wifi.router")
                segment("回線区間", ms: window.wanP50,
                        level: max(Level.internet(window.v4.p95), Level.loss(window.v4.loss)),
                        emphasized: highlight == .wan)
                node("インターネット", "globe.asia.australia")
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
            LatencySample(date: $0.date, router: $0.gw.rtts.max(), internet: $0.v4.rtts.max(), lost: $0.gw.lost + $0.v4.lost > 0)
        }
        LatencyLineChart(samples: samples, compact: compact)
            .equatable()
    }
}

struct LatencyLineChart: View, Equatable {
    let samples: [LatencySample]
    var compact = false

    var body: some View {
        Chart {
            ForEach(samples) { s in
                if let v = s.router {
                    LineMark(x: .value("時刻", s.date), y: .value("ms", max(0.1, v)), series: .value("宛先", SeriesName.router))
                        .foregroundStyle(by: .value("宛先", SeriesName.router))
                }
                if let v = s.internet {
                    LineMark(x: .value("時刻", s.date), y: .value("ms", max(0.1, v)), series: .value("宛先", SeriesName.internet))
                        .foregroundStyle(by: .value("宛先", SeriesName.internet))
                }
                if s.lost {
                    RuleMark(x: .value("時刻", s.date))
                        .foregroundStyle(.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartForegroundStyleScale([SeriesName.router: SeriesColor.router, SeriesName.internet: SeriesColor.inet4])
        .chartYScale(type: .log)
        .chartYAxisLabel(compact ? "" : "ms")
        .chartYAxis(compact ? .hidden : .automatic)
        .chartLegend(compact ? .hidden : .visible)
        .chartLegend(position: .top, alignment: .trailing)
        .transaction { $0.animation = nil }
    }
}
