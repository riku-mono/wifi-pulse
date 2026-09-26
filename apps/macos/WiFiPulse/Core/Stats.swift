import Foundation
import SwiftUI

/// ping の結果を集計したもの。JSONのキーは Python 版キットの `loadtests.jsonl` などと揃えてある。
nonisolated struct PingStats: Codable, Hashable, Sendable {
    var n: Int
    var lost: Int
    var min: Double?
    var p50: Double?
    var p95: Double?
    var p99: Double?
    var max: Double?
    var jitter: Double?

    static let empty = PingStats(n: 0, lost: 0)

    init(n: Int, lost: Int, min: Double? = nil, p50: Double? = nil, p95: Double? = nil,
         p99: Double? = nil, max: Double? = nil, jitter: Double? = nil) {
        self.n = n; self.lost = lost; self.min = min; self.p50 = p50
        self.p95 = p95; self.p99 = p99; self.max = max; self.jitter = jitter
    }

    /// `seq` は到着順の往復時間（ミリ秒）。ゆらぎは隣り合うサンプル差の平均（RFC 3550 に近い考え方）。
    init(_ seq: [Double], lost: Int) {
        guard !seq.isEmpty else { self.init(n: 0, lost: lost); return }
        let s = seq.sorted()
        func q(_ p: Double) -> Double { s[Swift.min(s.count - 1, Swift.max(0, Int((p * Double(s.count - 1)).rounded())))] }
        var j = 0.0
        for i in 1..<Swift.max(1, seq.count) { j += abs(seq[i] - seq[i - 1]) }
        self.init(n: seq.count, lost: lost, min: s.first, p50: q(0.5), p95: q(0.95), p99: q(0.99),
                  max: s.last, jitter: seq.count > 1 ? j / Double(seq.count - 1) : 0)
    }

    /// 0...1 のロス率。送信が無ければ nil。
    var loss: Double? { n + lost == 0 ? nil : Double(lost) / Double(n + lost) }
}

nonisolated func percentile(_ sorted: [Double], _ q: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let i = min(sorted.count - 1, max(0, Int((q * Double(sorted.count - 1)).rounded())))
    return sorted[i]
}

nonisolated func median(_ values: [Double]) -> Double? {
    let v = values.sorted()
    guard !v.isEmpty else { return nil }
    return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
}

// MARK: - Levels

/// 判定の段階。色だけに頼らず、必ず記号や文言と組み合わせて表示する。
nonisolated enum Level: Int, Comparable, Sendable {
    case none, good, warn, crit

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var tint: Color {
        switch self {
        case .none: .secondary
        case .good: .green
        case .warn: .orange
        case .crit: .red
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dotted"
        case .good: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .crit: "xmark.octagon.fill"
        }
    }

    static func rssi(_ v: Int?) -> Level {
        guard let v else { return .none }
        return v >= -60 ? .good : v >= -70 ? .warn : .crit
    }
    static func gateway(_ v: Double?) -> Level {
        guard let v else { return .none }
        return v < 10 ? .good : v < 30 ? .warn : .crit
    }
    static func internet(_ v: Double?) -> Level {
        guard let v else { return .none }
        return v < 30 ? .good : v < 80 ? .warn : .crit
    }
    static func loss(_ f: Double?) -> Level {
        guard let f else { return .none }
        return f == 0 ? .good : f < 0.01 ? .warn : .crit
    }
    static func dns(_ v: Double?) -> Level {
        guard let v else { return .none }
        return v < 30 ? .good : v < 100 ? .warn : .crit
    }
    static func rpm(_ v: Double?) -> Level {
        guard let v else { return .none }
        return v >= 800 ? .good : v >= 300 ? .warn : .crit
    }
}

// MARK: - Formatting

enum Fmt {
    static func ms(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))
    }

    static func mbps(_ bps: Double?) -> String {
        guard let bps else { return "—" }
        let m = bps / 1e6
        return m < 1 ? String(format: "%.2f", m) : m < 10 ? String(format: "%.1f", m) : String(Int(m.rounded()))
    }

    static func pct(_ f: Double?) -> String {
        guard let f else { return "—" }
        let p = f * 100
        return p == 0 ? "0" : p < 0.1 ? "<0.1" : String(format: "%.1f", p)
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .standard) }
    static func stamp(_ d: Date) -> String { d.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) }
}

extension Date {
    nonisolated var epochMs: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    nonisolated init(epochMs: Int64) { self.init(timeIntervalSince1970: Double(epochMs) / 1000) }

    /// Python の `time.localtime().tm_wday` と同じ（月曜=0 … 日曜=6）。
    nonisolated var pythonWeekday: Int { (Calendar.current.component(.weekday, from: self) + 5) % 7 }
    nonisolated var hour: Int { Calendar.current.component(.hour, from: self) }
}
