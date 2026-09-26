import Charts
import SwiftUI

/// いま接続している Wi-Fi の詳細
struct WirelessView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.location.isAuthorized {
                    LocationBanner()
                }
                LinkSection()
                Card("Signal and Noise (Last 10 Minutes)", systemImage: "chart.xyaxis.line", subtitle: String(localized: "Median every 5 seconds. The gap between the lines is the SNR — the wider, the better.")) {
                    SignalHistory()
                        .frame(height: 240)
                }
            }
            .padding(24)
        }
        .navigationTitle("Wi-Fi Connection")
    }
}

struct LocationBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "location.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network names and detailed radio information require Location access").font(.headline)
                    Text("macOS doesn’t give apps the SSID, BSSID, or beacon details without Location access. Your location itself is never recorded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Allow…") { model.location.request() }
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

/// リンク情報は値が変わったときだけ描き直す（RSSI は毎秒変わるので実際には毎秒だが、ここは軽い）
private struct LinkSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let link = model.monitor.live.link, link.powerOn {
            VStack(alignment: .leading, spacing: 16) {
                if link.isDFS {
                    Card {
                        ObservationRow(level: .warn,
                                       text: String(localized: "Channel \(link.channel ?? 0) is a DFS channel (W53/W56)"),
                                       detail: String(localized: "When weather or aviation radar is detected, the router can’t transmit at all for up to 60 seconds — a classic cause of traffic stalling for tens of seconds. Fixing your router to W52 (channels 36/40/44/48) stops it."))
                    }
                }
                LinkCard(link: link).equatable()
            }
        } else {
            ContentUnavailableView("Not Connected to Wi-Fi", systemImage: "wifi.slash",
                                   description: Text("Turn on Wi-Fi and join a network to see signal details."))
        }
    }
}

private struct LinkCard: View, Equatable {
    let link: LinkSample

    var body: some View {
        Card("Connected Network", systemImage: "wifi") {
            HStack(spacing: 12) {
                SignalBars(bars: link.bars).tint(Level.rssi(link.rssi).tint)
                Text(link.ssid ?? String(localized: "(network name hidden)"))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("Signal Strength", String(localized: "\(link.rssi) dBm (\(link.strengthWord))"), level: Level.rssi(link.rssi))
                row("Noise", "\(link.noise) dBm")
                row("SNR", "\(link.snr) dB", level: link.snr >= 25 ? .good : link.snr >= 15 ? .warn : .crit)
                row("Band / Channel", "\(link.bandLabel) · \(link.channelLabel)", level: link.isDFS ? .warn : .none)
                row("Standard", link.phy)
                row("Link Rate", "\(Int(link.txRate)) Mbps")
                row("Transmit Power", "\(link.txPower) mW")
                row("BSSID", link.bssid ?? "—")
            }
            .font(.callout)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String, level: Level = .none) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value).monospacedDigit().textSelection(.enabled)
                if level != .none {
                    Image(systemName: level.symbol).foregroundStyle(level.tint).imageScale(.small)
                }
            }
        }
    }
}

/// 5秒ごとに1点。`revision / 5` が変わったときだけ組み立て直す。
private struct SignalHistory: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let key = model.monitor.revision / 5
        SignalChart(points: points(key)).equatable()
    }

    private func points(_: Int) -> [SignalChart.Point] {
        let slice = model.monitor.recent(600)
        guard let first = slice.first?.date else { return [] }
        var buckets: [Int: [(Int, Int)]] = [:]
        for t in slice {
            guard let l = t.link else { continue }
            buckets[Int(t.date.timeIntervalSince(first) / 5), default: []].append((l.rssi, l.noise))
        }
        return buckets.keys.sorted().compactMap { i in
            let b = buckets[i]!
            guard let r = median(b.map { Double($0.0) }), let n = median(b.map { Double($0.1) }) else { return nil }
            return .init(date: first.addingTimeInterval(Double(i * 5)), rssi: r, noise: n)
        }
    }
}

private struct SignalChart: View, Equatable {
    struct Point: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let rssi: Double
        let noise: Double
    }
    let points: [Point]

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), yStart: .value("Noise", p.noise), yEnd: .value("Signal", p.rssi))
                    .foregroundStyle(.tint.opacity(0.15))
                LineMark(x: .value("Time", p.date), y: .value("dBm", p.rssi), series: .value("Series", "Signal"))
                    .foregroundStyle(.tint)
                LineMark(x: .value("Time", p.date), y: .value("dBm", p.noise), series: .value("Series", "Noise"))
                    .foregroundStyle(.secondary)
            }
            RuleMark(y: .value("Guide", -70))
                .foregroundStyle(.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("-70 dBm").font(.caption2).foregroundStyle(.orange)
                }
        }
        .chartYScale(domain: -100 ... -20)
        .chartYAxisLabel("dBm")
        .transaction { $0.animation = nil }
    }
}
