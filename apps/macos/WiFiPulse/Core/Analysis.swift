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
            return .init(level: .none, tag: String(localized: "判定中"), text: String(localized: "データを集めています。"), segment: nil)
        }
        if let link, link.rssi <= -75 {
            return .init(level: .crit, tag: String(localized: "電波が弱い"), text: String(localized: "ルーターから遠いか、間に障害物があります。ルーターに近づくと改善します。"), segment: .wifi)
        }
        if lossGw > 0.01 || (w.gw.p95 ?? 0) > 30 {
            return .init(level: .warn, tag: String(localized: "Wi-Fi区間"), text: String(localized: "家の中の Wi-Fi 区間が混み合っています（近隣のWi-Fi、電子レンジ、同時に使う端末など）。"), segment: .wifi)
        }
        if lossV4 > 0.01 || ((w.v4.p95 ?? 0) - (w.gw.p95 ?? 0) > 50 && w.v4.p95 != nil && w.gw.p95 != nil) {
            return .init(level: .warn, tag: String(localized: "回線区間"), text: String(localized: "Wi-Fi は正常です。遅れはインターネット回線側（プロバイダや経路）で起きています。"), segment: .wan)
        }
        return .init(level: .good, tag: String(localized: "ボトルネックなし"), text: String(localized: "Wi-Fi 区間も回線区間も問題ありません。"), segment: nil)
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
        guard let score else { return (String(localized: "測定中…"), .none) }
        return score >= 85 ? (String(localized: "快適"), .good) : score >= 65 ? (String(localized: "おおむね良好"), .good) : score >= 40 ? (String(localized: "やや不安定"), .warn) : (String(localized: "不調"), .crit)
    }

    static func sentence(_ w: WindowStats, short: WindowStats, link: LinkSample?) -> String {
        guard !w.isEmpty else { return String(localized: "データを集めています。") }
        let sig = link?.strengthWord ?? "—"
        let lat = short.v4.p50
        let latWord = lat.map { $0 < 15 ? String(localized: "とても速い") : $0 < 40 ? String(localized: "速い") : $0 < 100 ? String(localized: "普通") : String(localized: "遅い") } ?? "—"
        let loss = w.worstLoss, jit = w.v4.jitter ?? 0
        let stab = loss == 0 && jit < 5 ? String(localized: "途切れもありません。") : loss < 0.01 && jit < 15 ? String(localized: "わずかに揺らぎがあります。") : String(localized: "途切れや揺らぎが出ています。")
        return String(localized: "電波は\(sig)、反応は\(latWord)状態です。\(stab)")
    }

    static func stability(_ w: WindowStats) -> (String, Level) {
        guard w.v4.n + w.gw.n > 0 else { return ("—", .none) }
        let loss = w.worstLoss, jit = w.v4.jitter ?? 0
        if loss == 0 && jit < 5 { return (String(localized: "安定"), .good) }
        if loss < 0.01 && jit < 15 { return (String(localized: "ほぼ安定"), .warn) }
        return (String(localized: "不安定"), .crit)
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
        case 1..<6: return .init(name: String(localized: "深夜帯"), level: .good, note: String(localized: "\(day)の深夜。近隣も回線も最も空いている時間帯なので、数値は良く出やすくなります（ベストケース）。"))
        case 6..<9: return .init(name: String(localized: "朝"), level: .good, note: String(localized: "\(day)の朝。混雑は少なめです。"))
        case 9..<12: return weekend
            ? .init(name: String(localized: "休日の午前"), level: .warn, note: String(localized: "休日の午前。家にいる人が多く、やや混み始めます。"))
            : .init(name: String(localized: "平日の午前"), level: .good, note: String(localized: "平日の午前。在宅勤務があると少し混みますが、全体としては空いています。"))
        case 12..<18: return weekend
            ? .init(name: String(localized: "休日の昼"), level: .warn, note: String(localized: "休日の昼。動画視聴などで近隣の利用が増える時間帯です。"))
            : .init(name: String(localized: "平日の日中"), level: .good, note: String(localized: "平日の日中。比較的空いています。"))
        case 18..<20: return .init(name: String(localized: "夕方"), level: .warn, note: String(localized: "夕方。帰宅に合わせて混雑が増え始める時間帯です。"))
        default: return .init(name: String(localized: "ピーク帯"), level: .crit, note: String(localized: "\(day)の夜。1日で最も混雑する時間帯（20〜23時前後）です。ここでの数値が「普段の最低ライン」の目安になります。"))
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
        case .all: String(localized: "すべて")
        case .weekday: String(localized: "平日")
        case .weekend: String(localized: "休日")
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

    static func load(hours: Int?) -> RecordSet {
        let cutoff = hours.map { Date().addingTimeInterval(-Double($0) * 3600).epochMs } ?? 0
        return RecordSet(
            minutes: DataStore.load(DataStore.minutes, as: MinuteRow.self).filter { $0.t >= cutoff },
            speed: DataStore.load(DataStore.speedtests, as: SpeedTestRecord.self).filter { $0.t >= cutoff },
            loads: DataStore.load(DataStore.loadtests, as: LoadTestRecord.self).filter { $0.t >= cutoff }
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
            f.append(.init(severity: 2, title: String(localized: "\(worst.hour)時台にネット遅延が \(r1(base))ms → \(r1(wv))ms へ悪化"),
                           detail: String(localized: "特定の時間帯だけ悪いのは、回線側（プロバイダの混雑）の典型的なパターンです。"),
                           advice: String(localized: "PPPoE 接続なら IPoE（IPv6 接続方式）への切り替えが最も効きます。")))
        }
        let lossy = active.filter { ($0.loss ?? 0) > 0.005 }
        if !lossy.isEmpty {
            let hh = lossy.prefix(5).map { String(localized: "\($0.hour)時台(\(Fmt.pct($0.loss))%)") }.joined(separator: "、")
            f.append(.init(severity: 3, title: String(localized: "パケットロスが出ている時間帯: \(hh)"),
                           detail: String(localized: "1%を超えると、ビデオ通話やゲームで途切れがはっきり分かります。"), advice: nil))
        }

        // 区間の切り分け
        if !r.minutes.isEmpty {
            let g = median(r.minutes.compactMap(\.gw50))
            let gmax = r.minutes.compactMap(\.gw95).max()
            let vmax = r.minutes.compactMap(\.v495).max()
            if let g, g > 10 {
                f.append(.init(severity: 3, title: String(localized: "Wi-Fi区間の中央値が \(r1(g))ms と大きい"),
                               detail: String(localized: "健全なら1〜4msです。電波・チャンネルの混雑・ルーターの処理能力のいずれかが原因です。"),
                               advice: String(localized: "「周辺の Wi-Fi」で空いているチャンネルを確認してください。")))
            }
            if let gmax, gmax > 200 {
                f.append(.init(severity: 3, title: String(localized: "Wi-Fi区間で最大 \(r1(gmax))ms のスパイク"),
                               detail: String(localized: "ルーターまでの1ホップでこれが出るなら、原因は家の中にあります。"),
                               advice: String(localized: "「Wi-Fi イベント」で同じ時刻の切断・スキャン・レーダー検出を確認してください。")))
            } else if let vmax, vmax > 500 {
                f.append(.init(severity: 2, title: String(localized: "回線側で最大 \(r1(vmax))ms のスパイク"),
                               detail: String(localized: "Wi-Fi は正常で、遅れはプロバイダ側か経路で起きています。"), advice: nil))
            }
            if let lgw = median(r.minutes.compactMap(\.lgw)), lgw > 0.002 {
                f.append(.init(severity: 3, title: String(localized: "Wi-Fi区間でパケットロス \(Fmt.pct(lgw))%"),
                               detail: String(localized: "無線の状態が悪く、ルーターまでの間でパケットが失われています。"),
                               advice: String(localized: "ルーターに近づく・障害物を減らす・混雑していないチャンネルへ変えるのが有効です。")))
            }
            if let rs = median(r.minutes.compactMap(\.rssi)) {
                if rs <= -70 {
                    f.append(.init(severity: 3, title: String(localized: "電波強度 \(Int(rs)) dBm は弱すぎる"),
                                   detail: String(localized: "-60dBm 以上が目安です。"), advice: String(localized: "ルーターとの距離・障害物・設置場所を見直してください。")))
                } else if rs <= -60 {
                    f.append(.init(severity: 1, title: String(localized: "電波強度 \(Int(rs)) dBm はやや弱い"),
                                   detail: String(localized: "混雑時に速度が落ちやすくなります。"), advice: nil))
                }
            }
        }

        // バッファブロート
        let grades = r.loads.compactMap(\.worst_grade)
        if grades.contains(where: { ["D", "F"].contains($0) }) {
            f.append(.init(severity: 4, title: String(localized: "バッファブロートが深刻（判定D〜F）"),
                           detail: String(localized: "回線が埋まった瞬間に、遅延が数百ms〜数秒に跳ね上がります。大きなダウンロード中に通話やゲームが止まるのはこれが原因です。"),
                           advice: String(localized: "ルーターの QoS / SQM を有効にするか、上り帯域を実測値の90%程度に制限してください。")))
        } else if grades.contains(where: { ["B", "C"].contains($0) }) {
            f.append(.init(severity: 2, title: String(localized: "軽度〜中程度のバッファブロートあり"),
                           detail: String(localized: "家族が動画を見ている時間帯などに、反応が遅くなることがあります。"), advice: nil))
        }

        // 速度測定
        if let rpm = median(r.speed.compactMap(\.dl_rpm)), rpm < 300 {
            f.append(.init(severity: 4, title: String(localized: "下り負荷時の応答性が \(Int(rpm)) RPM（300未満＝悪い）"),
                           detail: String(localized: "回線が混むと、リアルタイムの通信がまともに成立しない水準です。"), advice: nil))
        }
        if let rpm = median(r.speed.compactMap(\.ul_rpm)), rpm < 300 {
            f.append(.init(severity: 4, title: String(localized: "上り負荷時の応答性が \(Int(rpm)) RPM（300未満＝悪い）"),
                           detail: String(localized: "アップロード中に、ほかの通信が大きく遅れます。"), advice: nil))
        }
        let dl = r.speed.map(\.dl).filter { $0 > 0 }
        if dl.count >= 3, let lo = dl.min(), let hi = dl.max(), lo < hi * 0.3 {
            f.append(.init(severity: 2, title: String(localized: "速度のばらつきが大きい（\(r1(lo))〜\(r1(hi)) Mbps）"),
                           detail: String(localized: "時間帯によって速度が大きく変わっています。"), advice: String(localized: "測った時刻を上のグラフと突き合わせてください。")))
        }
        return f.sorted { $0.severity > $1.severity }
    }

    static func markdown(_ r: RecordSet, findings: [Finding]) -> String {
        var out = [String(localized: "# ネットワーク診断レポート"), "", String(localized: "生成: \(Date().formatted(date: .numeric, time: .standard))"), ""]
        out.append(String(localized: "## 集まっているデータ"))
        out.append(String(localized: "- 常時計測: \(r.minutes.count)分ぶん（\(String(format: "%.1f", Double(r.minutes.count) / 60)) 時間）"))
        out.append(String(localized: "- 速度測定 \(r.speed.count)回 / 負荷試験 \(r.loads.count)回"))
        out.append("")
        out.append(String(localized: "## 所見（深刻な順）"))
        if findings.isEmpty {
            out.append(String(localized: "目立つ異常は見つからなかった。"))
        }
        for (i, f) in findings.enumerated() {
            let mark = [4: "🔴", 3: "🟠", 2: "🟡", 1: "⚪"][f.severity] ?? "・"
            out.append("\(i + 1). \(mark) **\(f.title)**。\(f.detail)" + (f.advice.map { " \($0)" } ?? ""))
        }
        return out.joined(separator: "\n")
    }
}
