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
        #expect(row.self_s == 10)
    }

    /// 除いた秒が無ければ `self_s` は書かない（Python 版キットと古い記録の形のまま）
    @Test func minuteRowOmitsSelfSecondsWhenNothingExcluded() throws {
        let row = try #require(Monitor.minuteRow((0..<60).map { Self.tick($0, gw: 8) }, network: nil))
        #expect(row.self_s == nil)
        let line = String(decoding: try #require(DataStore.line(row)), as: UTF8.self)
        #expect(!line.contains("self_s"))
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

    /// 数秒で終わる掃引だけは表示を止めない
    @Test func pausesJudgement() {
        #expect(Exclusion.warmup.pausesJudgement)
        #expect(Exclusion.speedTest.pausesJudgement)
        #expect(Exclusion.loadTest.pausesJudgement)
        #expect(!Exclusion.lanScan.pausesJudgement)
    }

    /// 測定が終わってからも `tail` 秒は印を付け続ける
    @Test func selfLoadMarkerKeepsTheTail() {
        var m = SelfLoadMarker()
        func at(_ s: Double) -> Date { Self.start.addingTimeInterval(s) }
        #expect(m.mark(nil, at: at(0)) == nil)
        #expect(m.mark(.speedTest, at: at(1)) == .speedTest)
        #expect(m.mark(.speedTest, at: at(20)) == .speedTest)
        #expect(m.mark(nil, at: at(21)) == .speedTest)
        #expect(m.mark(nil, at: at(20 + SelfLoadMarker.tail - 1)) == .speedTest)
        #expect(m.mark(nil, at: at(20 + SelfLoadMarker.tail)) == nil)
        #expect(m.mark(.loadTest, at: at(40)) == .loadTest)
        #expect(m.mark(nil, at: at(41)) == .loadTest)
    }

    /// 帯は続いている秒ごとにまとめる（`Tick.date` はその1秒の終わりなので、1秒前から始める）
    @Test func excludedSpans() {
        func at(_ s: Double) -> Date { Self.start.addingTimeInterval(s) }
        #expect(LatencySeries.spans([]).isEmpty)
        let spans = LatencySeries.spans([3, 4, 5, 10, 11].map(at))
        #expect(spans == [at(2)...at(5), at(9)...at(11)])
    }

    @Test func latencySeriesCarriesExcludedSpans() {
        let ticks = (0..<30).map { Self.tick($0, gw: 8, excluded: (10..<15).contains($0) ? .speedTest : nil) }
        let series = LatencySeries.make(ticks[...], seconds: 30)
        #expect(series.excluded == [Self.start.addingTimeInterval(9)...Self.start.addingTimeInterval(14)])
        // 線は消さない
        #expect(series.points.contains { $0.date >= Self.start.addingTimeInterval(10) && $0.date <= Self.start.addingTimeInterval(14) })
    }
}
