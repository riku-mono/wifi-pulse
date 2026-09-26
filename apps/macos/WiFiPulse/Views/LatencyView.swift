import Charts
import SwiftUI

struct LatencyView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("latencyRange") private var range: Range = .m2

    enum Range: Int, CaseIterable, Identifiable {
        case m2 = 120, m10 = 600, m60 = 3600
        var id: Self { self }
        var label: LocalizedStringKey {
            switch self {
            case .m2: "2分"
            case .m10: "10分"
            case .m60: "60分"
            }
        }
        /// 何秒ごとに描き直すか。範囲が広いほど1秒の変化は見えないので間引く。
        var refreshEvery: Int {
            switch self {
            case .m2: 1
            case .m10: 3
            case .m60: 15
            }
        }
    }

    var body: some View {
        let key = model.monitor.revision / range.refreshEvery
        LatencyContent(range: range, key: key)
            .equatable()
            .navigationTitle("遅延")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("表示範囲", selection: $range) {
                        ForEach(Range.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
    }
}

/// `key` が変わったときだけ中身を組み立て直す。
private struct LatencyContent: View, Equatable {
    @Environment(AppModel.self) private var model
    let range: LatencyView.Range
    let key: Int

    static func == (a: Self, b: Self) -> Bool { a.range == b.range && a.key == b.key }

    var body: some View {
        let m = model.monitor
        let slice = m.recent(range.rawValue)
        let w = m.window(range.rawValue)
        let series = LatencySeries.make(slice, seconds: range.rawValue)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card("遅延の推移", systemImage: "waveform.path.ecg",
                     subtitle: "線は中央値、帯は最大値までの幅。赤い縦線はパケットロス。縦軸は対数。") {
                    LatencyBandChart(series: series).equatable()
                        .frame(height: 280)
                }

                HStack(alignment: .top, spacing: 16) {
                    Card("統計", systemImage: "tablecells", subtitle: "直近\(range.rawValue / 60)分") {
                        PingStatsGrid(rows: [
                            ("ルーター \(m.env.gateway)", w.gw),
                            ("IPv4 \(m.inet4Target)", w.v4),
                            ("IPv6", w.v6),
                        ])
                    }
                    Card("遅延の分布", systemImage: "chart.bar", subtitle: "ping 1回ごとの件数") {
                        HistogramChart(bins: HistogramChart.bins(slice)).equatable()
                            .frame(height: 160)
                    }
                }

                Card("DNS の応答時間", systemImage: "character.book.closed", subtitle: "ルーターの DNS に www.apple.com を問い合わせた時間（10秒ごと）") {
                    DNSChart(samples: m.dns).equatable()
                        .frame(height: 120)
                }
            }
            .padding(24)
        }
    }
}

struct LatencySeries: Equatable {
    struct Point: Identifiable, Equatable {
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
        let date: Date
        let series: String
        let p50: Double
        let max: Double
    }
    var points: [Point] = []
    var losses: [Date] = []
    var domain: ClosedRange<Date> = Date()...Date()

    /// 表示範囲を約240区間に分け、区間ごとの中央値と最大値を出す
    static func make(_ ticks: ArraySlice<Tick>, seconds: Int) -> LatencySeries {
        guard let end = ticks.last?.date else { return LatencySeries() }
        let start = end.addingTimeInterval(-Double(seconds))
        let size = max(1.0, Double(seconds) / 240)
        var buckets: [Int: (gw: [Double], v4: [Double], v6: [Double])] = [:]
        var losses: [Date] = []
        for t in ticks {
            let i = Int(t.date.timeIntervalSince(start) / size)
            buckets[i, default: ([], [], [])].gw += t.gw.rtts
            buckets[i, default: ([], [], [])].v4 += t.v4.rtts
            buckets[i, default: ([], [], [])].v6 += t.v6.rtts
            if t.gw.lost + t.v4.lost > 0 { losses.append(t.date) }
        }
        var out: [Point] = []
        out.reserveCapacity(buckets.count * 3)
        for (i, b) in buckets.sorted(by: { $0.key < $1.key }) {
            let d = start.addingTimeInterval(Double(i) * size)
            for (name, vals) in [("ルーター", b.gw), ("IPv4", b.v4), ("IPv6", b.v6)] {
                if let p = median(vals), let mx = vals.max() {
                    out.append(Point(date: d, series: name, p50: max(0.1, p), max: max(0.1, mx)))
                }
            }
        }
        return LatencySeries(points: out, losses: losses, domain: start...end)
    }
}

private struct LatencyBandChart: View, Equatable {
    let series: LatencySeries

    var body: some View {
        Chart {
            ForEach(series.points) { p in
                AreaMark(x: .value("時刻", p.date), yStart: .value("中央値", p.p50), yEnd: .value("最大", p.max),
                         series: .value("宛先", p.series))
                    .foregroundStyle(by: .value("宛先", p.series))
                    .opacity(0.18)
                LineMark(x: .value("時刻", p.date), y: .value("ms", p.p50), series: .value("宛先", p.series))
                    .foregroundStyle(by: .value("宛先", p.series))
            }
            ForEach(series.losses, id: \.self) { d in
                RuleMark(x: .value("ロス", d))
                    .foregroundStyle(.red.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: series.domain)
        .chartForegroundStyleScale(["ルーター": SeriesColor.router, "IPv4": SeriesColor.inet4, "IPv6": SeriesColor.inet6])
        .chartYScale(type: .log)
        .chartYAxisLabel("ms")
        .chartLegend(position: .top, alignment: .trailing)
        .transaction { $0.animation = nil }
    }
}

private struct HistogramChart: View, Equatable {
    struct Bin: Identifiable, Equatable {
        var id: String { "\(series)-\(label)" }
        let label: String
        let series: String
        let count: Int
    }
    let bins: [Bin]

    static let edges: [Double] = [0, 2, 5, 10, 20, 50, 100, 200, 500]
    static func label(_ i: Int) -> String {
        i == edges.count - 1 ? "\(Int(edges[i]))+" : "\(Int(edges[i]))–\(Int(edges[i + 1]))"
    }

    static func bins(_ slice: ArraySlice<Tick>) -> [Bin] {
        func count(_ kp: KeyPath<Tick, Pinger.Batch>, _ series: String) -> [Bin] {
            var c = Array(repeating: 0, count: edges.count)
            for t in slice {
                for v in t[keyPath: kp].rtts { c[(edges.lastIndex { v >= $0 }) ?? 0] += 1 }
            }
            return c.indices.map { Bin(label: label($0), series: series, count: c[$0]) }
        }
        return count(\.gw, "ルーター") + count(\.v4, "IPv4")
    }

    var body: some View {
        Chart(bins) { b in
            BarMark(x: .value("ms", b.label), y: .value("回数", b.count))
                .foregroundStyle(by: .value("宛先", b.series))
                .position(by: .value("宛先", b.series))
        }
        .chartForegroundStyleScale(["ルーター": SeriesColor.router, "IPv4": SeriesColor.inet4])
        .chartXAxisLabel("ms")
        .chartLegend(.hidden)
        .transaction { $0.animation = nil }
    }
}

private struct DNSChart: View, Equatable {
    let samples: [DNSSample]

    var body: some View {
        Chart(samples) { s in
            if let ms = s.ms {
                BarMark(x: .value("時刻", s.date, unit: .second), y: .value("ms", ms), width: .fixed(4))
                    .foregroundStyle(Level.dns(ms).tint)
            } else {
                RuleMark(x: .value("時刻", s.date)).foregroundStyle(.red)
            }
        }
        .chartYAxisLabel("ms")
    }
}
