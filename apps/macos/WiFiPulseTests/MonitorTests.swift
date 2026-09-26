import Foundation
import Testing
@testable import WiFiPulse

struct ExclusionTests {
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// ルーター宛て 5 発・インターネット宛て 2 発の 1 秒（`gw` の往復時間を指定する）
    static func tick(_ i: Int, gw: Double, lost: Int = 0, excluded: Exclusion? = nil) -> Tick {
        Tick(date: start.addingTimeInterval(Double(i)), link: nil,
             gw: .init(rtts: Array(repeating: gw, count: 5 - lost), lost: lost),
             v4: .init(rtts: [12, 13]), v6: .init(),
             rx: 1000, tx: 500, excluded: excluded)
    }

    /// 掃引の乱れ（跳ね・ロス）が入った秒を外せば、窓の値は乱れの無い秒だけから出る
    @Test func windowSkipsExcludedSeconds() {
        func ticks(marked: Bool) -> [Tick] {
            (0..<30).map { i in
                (3...4).contains(i) ? Self.tick(i, gw: 150, lost: 1, excluded: marked ? .lanScan : nil) : Self.tick(i, gw: 8)
            }
        }
        let w = Monitor.windowStats(ticks(marked: true), seconds: 30)
        #expect(w.gw.n == 28 * 5)
        #expect(w.gw.lost == 0)
        #expect(w.gw.p95 == 8)
        #expect(Analysis.score(w, link: nil) == 100)

        let raw = Monitor.windowStats(ticks(marked: false), seconds: 30)
        #expect(raw.gw.lost == 2)
        #expect((Analysis.score(raw, link: nil) ?? 100) < 100)
    }

    /// 慣らし運転の間は窓が空になり、スコアは出ない
    @Test func windowIsEmptyDuringWarmup() {
        let ticks = (0..<5).map { Self.tick($0, gw: 8, excluded: .warmup) }
        let w = Monitor.windowStats(ticks, seconds: 30)
        #expect(w.isEmpty)
        #expect(Analysis.score(w, link: nil) == nil)
    }

    @Test func minuteRowSkipsExcludedSeconds() throws {
        let ticks = (0..<60).map { i in i < 10 ? Self.tick(i, gw: 150, lost: 1, excluded: .warmup) : Self.tick(i, gw: 8) }
        let row = try #require(Monitor.minuteRow(ticks, network: "net"))
        #expect(row.n == 50)
        #expect(row.gw95 == 8)
        #expect(row.lgw == 0)
        #expect(row.t == Self.start.addingTimeInterval(10).epochMs)
        #expect(row.net == "net")
    }

    /// 残りが数秒だけなら 1分集計を書かない
    @Test func minuteRowNeedsEnoughSeconds() {
        let few = (0..<60).map { i in Self.tick(i, gw: 8, excluded: i < 55 ? .warmup : nil) }
        #expect(Monitor.minuteRow(few, network: nil) == nil)
        let short = (0..<(Monitor.minimumPartialMinute - 1)).map { Self.tick($0, gw: 8) }
        #expect(Monitor.minuteRow(short, network: nil) == nil)
        let enough = (0..<Monitor.minimumPartialMinute).map { Self.tick($0, gw: 8) }
        #expect(Monitor.minuteRow(enough, network: nil)?.n == Monitor.minimumPartialMinute)
    }

    @Test func progress() {
        let end = Self.start.addingTimeInterval(10)
        #expect(Monitor.progress(at: Self.start, end: end, length: 10) == 0)
        #expect(Monitor.progress(at: Self.start.addingTimeInterval(4), end: end, length: 10) == 0.4)
        #expect(Monitor.progress(at: end, end: end, length: 10) == 1)
        #expect(Monitor.progress(at: end.addingTimeInterval(5), end: end, length: 10) == 1)
        #expect(Monitor.progress(at: Self.start.addingTimeInterval(-5), end: end, length: 10) == 0)
    }

    @Test func onlyWarmupPausesJudgement() {
        #expect(Exclusion.warmup.pausesJudgement)
        #expect(!Exclusion.lanScan.pausesJudgement)
    }
}
