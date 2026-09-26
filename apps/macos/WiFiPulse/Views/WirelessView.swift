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
                Card("信号とノイズ（直近10分）", systemImage: "chart.xyaxis.line", subtitle: "5秒ごとの中央値。間の幅が SN比で、広いほど余裕があります。") {
                    SignalHistory()
                        .frame(height: 240)
                }
            }
            .padding(24)
        }
        .navigationTitle("Wi-Fi 接続")
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
                    Text("ネットワーク名と詳しい電波情報には位置情報の許可が必要です").font(.headline)
                    Text("macOS は位置情報の許可が無いアプリに SSID・BSSID・ビーコンの詳細を返しません。位置そのものは記録しません。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("許可する…") { model.location.request() }
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
                                       text: "\(link.channel ?? 0)ch は DFS 対象（W53/W56）です",
                                       detail: "気象・航空レーダーを検出すると、ルーターは最大60秒まったく送信できなくなります。通信が数十秒止まる症状の典型原因です。ルーターのチャンネルを W52（36/40/44/48ch）に固定すると止まります。")
                    }
                }
                LinkCard(link: link).equatable()
            }
        } else {
            ContentUnavailableView("Wi-Fi に接続していません", systemImage: "wifi.slash",
                                   description: Text("Wi-Fi をオンにしてネットワークに接続すると、電波の状態を表示します。"))
        }
    }
}

private struct LinkCard: View, Equatable {
    let link: LinkSample

    var body: some View {
        Card("接続中のネットワーク", systemImage: "wifi") {
            HStack(spacing: 12) {
                SignalBars(bars: link.bars).tint(Level.rssi(link.rssi).tint)
                Text(link.ssid ?? "（ネットワーク名は非表示）")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("電波強度", "\(link.rssi) dBm（\(link.strengthWord)）", level: Level.rssi(link.rssi))
                row("ノイズ", "\(link.noise) dBm")
                row("SN比", "\(link.snr) dB", level: link.snr >= 25 ? .good : link.snr >= 15 ? .warn : .crit)
                row("バンド / チャンネル", "\(link.bandLabel) · \(link.channelLabel)", level: link.isDFS ? .warn : .none)
                row("規格", link.phy)
                row("リンク速度", "\(Int(link.txRate)) Mbps")
                row("送信出力", "\(link.txPower) mW")
                row("BSSID", link.bssid ?? "—")
            }
            .font(.callout)
        }
    }

    private func row(_ title: String, _ value: String, level: Level = .none) -> some View {
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
                AreaMark(x: .value("時刻", p.date), yStart: .value("ノイズ", p.noise), yEnd: .value("信号", p.rssi))
                    .foregroundStyle(.tint.opacity(0.15))
                LineMark(x: .value("時刻", p.date), y: .value("dBm", p.rssi), series: .value("系列", "信号"))
                    .foregroundStyle(.tint)
                LineMark(x: .value("時刻", p.date), y: .value("dBm", p.noise), series: .value("系列", "ノイズ"))
                    .foregroundStyle(.secondary)
            }
            RuleMark(y: .value("目安", -70))
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
