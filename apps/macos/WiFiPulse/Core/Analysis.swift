import Foundation

/// いまの状態の判定（Web版ダッシュボードの score / bottleneck / timeBand と同じロジック）。
enum Analysis {
    struct Bottleneck: Equatable {
        let level: Level
        let tag: String
        let text: String
        /// どの区間が悪いか（経路図のハイライト用）
        let segment: Segment?
    }

    enum Segment { case wifi, wan }

    static func bottleneck(_ w: WindowStats, link: LinkSample?) -> Bottleneck {
        let lossGw = w.gw.loss ?? 0, lossV4 = w.v4.loss ?? 0
        if w.gw.n == 0 && w.v4.n == 0 {
            return .init(level: .none, tag: String(localized: "Evaluating"), text: String(localized: "Collecting data."), segment: nil)
        }
        if let link, link.rssi <= -75 {
            return .init(level: .crit, tag: String(localized: "Weak Signal"), text: String(localized: "You’re far from the router or something is in the way. Moving closer will help."), segment: .wifi)
        }
        if lossGw > 0.01 || (w.gw.p95 ?? 0) > 30 {
            return .init(level: .warn, tag: String(localized: "Wi-Fi segment"), text: String(localized: "The Wi-Fi segment in your home is congested (nearby Wi-Fi, microwaves, other devices in use, etc.)."), segment: .wifi)
        }
        if lossV4 > 0.01 || ((w.v4.p95 ?? 0) - (w.gw.p95 ?? 0) > 50 && w.v4.p95 != nil && w.gw.p95 != nil) {
            return .init(level: .warn, tag: String(localized: "Internet line"), text: String(localized: "Wi-Fi is fine. The delay is on the Internet side (your ISP or the route)."), segment: .wan)
        }
        return .init(level: .good, tag: String(localized: "No Bottleneck"), text: String(localized: "Both the Wi-Fi segment and the Internet line are healthy."), segment: nil)
    }

    /// 0〜100。電波・ルーター遅延・ネット遅延・ロス・ゆらぎの加重平均。
    static func score(_ w: WindowStats, link: LinkSample?) -> Int? {
        func lin(_ v: Double?, _ good: Double, _ bad: Double) -> Double? {
            guard let v else { return nil }
            return min(1, max(0, (bad - v) / (bad - good)))
        }
        let parts: [(Double?, Double)] = [
            (link.map { lin(Double(-$0.rssi), 60, 82) } ?? nil, 25),
            (lin(w.gw.p95, 10, 80), 20),
            (lin(w.v4.p95, 30, 200), 20),
            (w.gw.n + w.v4.n > 0 ? lin(w.worstLoss * 100, 0, 5) : nil, 25),
            (lin(w.v4.jitter, 3, 40), 10),
        ]
        var s = 0.0, wt = 0.0
        for (v, weight) in parts { if let v { s += v * weight; wt += weight } }
        return wt > 0 ? Int((s / wt * 100).rounded()) : nil
    }

    static func verdict(_ score: Int?) -> (String, Level) {
        guard let score else { return (String(localized: "Measuring…"), .none) }
        return score >= 85 ? (String(localized: "Excellent"), .good) : score >= 65 ? (String(localized: "Mostly Good"), .good) : score >= 40 ? (String(localized: "Somewhat Unstable"), .warn) : (String(localized: "Poor"), .crit)
    }

    static func sentence(_ w: WindowStats, short: WindowStats, link: LinkSample?) -> String {
        guard !w.isEmpty else { return String(localized: "Collecting data.") }
        let sig = link?.strengthWord ?? "—"
        let lat = short.v4.p50
        let latWord = lat.map { $0 < 15 ? String(localized: "very fast") : $0 < 40 ? String(localized: "fast") : $0 < 100 ? String(localized: "fair") : String(localized: "slow") } ?? "—"
        let loss = w.worstLoss, jit = w.v4.jitter ?? 0
        let stab = loss == 0 && jit < 5 ? String(localized: "No dropouts.") : loss < 0.01 && jit < 15 ? String(localized: "There is slight jitter.") : String(localized: "There are dropouts or jitter.")
        return String(localized: "Signal is \(sig) and response is \(latWord). \(stab)")
    }

    static func stability(_ w: WindowStats) -> (String, Level) {
        guard w.v4.n + w.gw.n > 0 else { return ("—", .none) }
        let loss = w.worstLoss, jit = w.v4.jitter ?? 0
        if loss == 0 && jit < 5 { return (String(localized: "Stable"), .good) }
        if loss < 0.01 && jit < 15 { return (String(localized: "Mostly Stable"), .warn) }
        return (String(localized: "Unstable"), .crit)
    }

    struct TimeBand {
        let name: String
        let level: Level
        let note: String
    }

    static func timeBand(_ d: Date = Date()) -> TimeBand {
        let cal = Calendar.current
        let h = cal.component(.hour, from: d), wd = cal.component(.weekday, from: d)
        let weekend = wd == 1 || wd == 7
        // 曜日名はロケールに任せる（日本語なら「土曜日」、英語なら「Saturday」）
        let day = d.formatted(.dateTime.weekday(.wide))
        switch h {
        case 1..<6: return .init(name: String(localized: "Late Night"), level: .good, note: String(localized: "\(day) late night — the quietest time for both nearby networks and your ISP, so numbers tend to look their best."))
        case 6..<9: return .init(name: String(localized: "Morning"), level: .good, note: String(localized: "\(day) morning. Networks are usually quiet."))
        case 9..<12: return weekend
            ? .init(name: String(localized: "Weekend Morning"), level: .warn, note: String(localized: "Weekend morning. More people are home, so networks start getting busier."))
            : .init(name: String(localized: "Weekday Morning"), level: .good, note: String(localized: "Weekday morning. Remote work adds a little load, but it’s generally quiet."))
        case 12..<18: return weekend
            ? .init(name: String(localized: "Weekend Afternoon"), level: .warn, note: String(localized: "Weekend afternoon. Nearby usage rises with video streaming and the like."))
            : .init(name: String(localized: "Weekday Daytime"), level: .good, note: String(localized: "Weekday daytime. Relatively quiet."))
        case 18..<20: return .init(name: String(localized: "Evening"), level: .warn, note: String(localized: "Evening. Congestion starts rising as people get home."))
        default: return .init(name: String(localized: "Peak Hours"), level: .crit, note: String(localized: "\(day) evening — the busiest time of day (around 8–11 PM). Numbers now show your everyday worst case."))
        }
    }
}

// MARK: - Hourly aggregation & findings (tools/report.py 相当)

struct HourRow: Identifiable, Sendable {
    var id: Int { hour }
    let hour: Int
    let minutes: Int
    let v4: Double?
    let v495: Double?
    let gw: Double?
    let loss: Double?
    let rssi: Double?
    let speedTests: Int
    let dl: Double?
    let ul: Double?
}


struct Finding: Identifiable, Sendable {
    let id = UUID()
    /// 1〜4（4が最も深刻）
    let severity: Int
    let title: String
    let detail: String
    /// 対策のヒント
    let advice: String?

    var level: Level { severity >= 3 ? .crit : severity == 2 ? .warn : .none }
}

enum DayFilter: String, CaseIterable, Identifiable {
    case all, weekday, weekend
    var id: Self { self }
    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .weekday: String(localized: "Weekdays")
        case .weekend: String(localized: "Weekends")
        }
    }
    func includes(_ wd: Int) -> Bool {
        switch self {
        case .all: true
        case .weekday: wd < 5
        case .weekend: wd >= 5
        }
    }
}

nonisolated struct RecordSet: Sendable {
    var minutes: [MinuteRow] = []
    var speed: [SpeedTestRecord] = []
    var loads: [LoadTestRecord] = []

    static func load(hours: Int?, network: NetworkFilter, networks: [String: KnownNetwork]) -> RecordSet {
        let cutoff = hours.map { Date().addingTimeInterval(-Double($0) * 3600).epochMs } ?? 0
        return RecordSet(
            minutes: DataStore.load(DataStore.minutes, as: MinuteRow.self).filter { $0.t >= cutoff && network.includes($0.net, in: networks) },
            speed: DataStore.load(DataStore.speedtests, as: SpeedTestRecord.self).filter { $0.t >= cutoff && network.includes($0.net, in: networks) },
            loads: DataStore.load(DataStore.loadtests, as: LoadTestRecord.self).filter { $0.t >= cutoff && network.includes($0.net, in: networks) }
        )
    }
}

enum Report {
    static func hourly(_ r: RecordSet, filter: DayFilter) -> [HourRow] {
        var byHour = Array(repeating: [MinuteRow](), count: 24)
        for m in r.minutes where filter.includes(m.wd) && (0..<24).contains(m.hour) { byHour[m.hour].append(m) }
        var tests = Array(repeating: [SpeedTestRecord](), count: 24)
        for s in r.speed where filter.includes(s.wd) && (0..<24).contains(s.hour) { tests[s.hour].append(s) }
        return (0..<24).map { h in
            let rs = byHour[h], ts = tests[h]
            return HourRow(hour: h, minutes: rs.count,
                           v4: median(rs.compactMap(\.v450)), v495: median(rs.compactMap(\.v495)),
                           gw: median(rs.compactMap(\.gw50)), loss: median(rs.compactMap(\.lv4)),
                           rssi: median(rs.compactMap(\.rssi)), speedTests: ts.count,
                           dl: median(ts.map(\.dl)), ul: median(ts.map(\.ul)))
        }
    }

    static func findings(_ r: RecordSet, hourly rows: [HourRow]) -> [Finding] {
        var f: [Finding] = []
        func r1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }

        // 時間帯
        let active = rows.filter { $0.minutes > 0 }
        if let base = active.compactMap(\.v4).min(), active.count >= 4,
           let worst = active.max(by: { ($0.v4 ?? 0) < ($1.v4 ?? 0) }), let wv = worst.v4, wv > base * 2, wv - base > 20 {
            f.append(.init(severity: 2, title: String(localized: "Internet latency worsens at \(worst.hour):00 (\(r1(base)) ms → \(r1(wv)) ms)"),
                           detail: String(localized: "Being bad only at certain times is a typical sign of congestion at your ISP."),
                           advice: String(localized: "If you connect via PPPoE, switching to IPoE (IPv6-based access) helps the most.")))
        }
        let lossy = active.filter { ($0.loss ?? 0) > 0.005 }
        if !lossy.isEmpty {
            let hh = lossy.prefix(5).map { String(localized: "\($0.hour):00 (\(Fmt.pct($0.loss))%)") }.formatted(.list(type: .and))
            f.append(.init(severity: 3, title: String(localized: "Hours with packet loss: \(hh)"),
                           detail: String(localized: "Above 1%, dropouts become clearly noticeable in video calls and games."), advice: nil))
        }

        // 区間の切り分け
        if !r.minutes.isEmpty {
            let g = median(r.minutes.compactMap(\.gw50))
            let gmax = r.minutes.compactMap(\.gw95).max()
            let vmax = r.minutes.compactMap(\.v495).max()
            if let g, g > 10 {
                f.append(.init(severity: 3, title: String(localized: "High median latency on the Wi-Fi segment: \(r1(g)) ms"),
                               detail: String(localized: "A healthy value is 1–4 ms. The cause is the signal, channel congestion, or the router’s processing power."),
                               advice: String(localized: "Check Nearby Wi-Fi for a less congested channel.")))
            }
            if let gmax, gmax > 200 {
                f.append(.init(severity: 3, title: String(localized: "Spikes up to \(r1(gmax)) ms on the Wi-Fi segment"),
                               detail: String(localized: "If this happens on the single hop to your router, the cause is inside your home."),
                               advice: String(localized: "Check Wi-Fi Events for disconnects, scans, or radar detection at the same time.")))
            } else if let vmax, vmax > 500 {
                f.append(.init(severity: 2, title: String(localized: "Spikes up to \(r1(vmax)) ms on the Internet line"),
                               detail: String(localized: "Wi-Fi is fine; the delay is at your ISP or further along the route."), advice: nil))
            }
            if let lgw = median(r.minutes.compactMap(\.routerLoss)), lgw > 0.002 {
                f.append(.init(severity: 3, title: String(localized: "Packet loss on the Wi-Fi segment: \(Fmt.pct(lgw))%"),
                               detail: String(localized: "Wireless conditions are poor and packets are lost on the way to the router."),
                               advice: String(localized: "Move closer to the router, reduce obstacles, or switch to a less congested channel.")))
            }
            if let rs = median(r.minutes.compactMap(\.rssi)) {
                if rs <= -70 {
                    f.append(.init(severity: 3, title: String(localized: "Signal strength of \(Int(rs)) dBm is too weak"),
                                   detail: String(localized: "Aim for -60 dBm or stronger."), advice: String(localized: "Review the distance to the router, obstacles, and where it’s placed.")))
                } else if rs <= -60 {
                    f.append(.init(severity: 1, title: String(localized: "Signal strength of \(Int(rs)) dBm is somewhat weak"),
                                   detail: String(localized: "Speed tends to drop when the network is busy."), advice: nil))
                }
            }
        }

        // バッファブロート
        let grades = r.loads.compactMap(\.worst_grade)
        if grades.contains(where: { ["D", "F"].contains($0) }) {
            f.append(.init(severity: 4, title: String(localized: "Severe bufferbloat (grade D–F)"),
                           detail: String(localized: "When the connection saturates, latency jumps to hundreds of milliseconds or several seconds. This is why calls and games freeze during large downloads."),
                           advice: String(localized: "Enable QoS / SQM on your router, or limit upload bandwidth to about 90% of the measured speed.")))
        } else if grades.contains(where: { ["B", "C"].contains($0) }) {
            f.append(.init(severity: 2, title: String(localized: "Mild to moderate bufferbloat"),
                           detail: String(localized: "Responsiveness may drop when, for example, someone at home is streaming video."), advice: nil))
        }

        // 速度測定
        if let rpm = median(r.speed.compactMap(\.dl_rpm)), rpm < 300 {
            f.append(.init(severity: 4, title: String(localized: "Responsiveness under download load is \(Int(rpm)) RPM (under 300 is poor)"),
                           detail: String(localized: "When the connection is busy, real-time communication barely works."), advice: nil))
        }
        if let rpm = median(r.speed.compactMap(\.ul_rpm)), rpm < 300 {
            f.append(.init(severity: 4, title: String(localized: "Responsiveness under upload load is \(Int(rpm)) RPM (under 300 is poor)"),
                           detail: String(localized: "Other traffic is heavily delayed during uploads."), advice: nil))
        }
        let dl = r.speed.map(\.dl).filter { $0 > 0 }
        if dl.count >= 3, let lo = dl.min(), let hi = dl.max(), lo < hi * 0.3 {
            f.append(.init(severity: 2, title: String(localized: "Speed varies widely (\(r1(lo))–\(r1(hi)) Mbps)"),
                           detail: String(localized: "Speed varies a lot by time of day."), advice: String(localized: "Compare the test times with the chart above.")))
        }
        return f.sorted { $0.severity > $1.severity }
    }

    static func markdown(_ r: RecordSet, findings: [Finding], network: String) -> String {
        var out = [String(localized: "# Network Diagnostics Report"), "", String(localized: "Generated: \(Date().formatted(date: .numeric, time: .standard))"), ""]
        out.append(String(localized: "## Collected data"))
        out.append(String(localized: "- Network: \(network)"))
        out.append(String(localized: "- Continuous monitoring: \(r.minutes.count) min (\(String(format: "%.1f", Double(r.minutes.count) / 60)) h)"))
        out.append(String(localized: "- Speed tests: \(r.speed.count) / Load tests: \(r.loads.count)"))
        out.append("")
        out.append(String(localized: "## Findings (most severe first)"))
        if findings.isEmpty {
            out.append(String(localized: "No notable problems were found."))
        }
        for (i, f) in findings.enumerated() {
            let mark = [4: "🔴", 3: "🟠", 2: "🟡", 1: "⚪"][f.severity] ?? "•"
            out.append("\(i + 1). \(mark) **\(f.title)** — \(f.detail)" + (f.advice.map { " \($0)" } ?? ""))
        }
        return out.joined(separator: "\n")
    }
}
