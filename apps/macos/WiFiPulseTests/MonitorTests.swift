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

    /// 数秒で終わる掃引・スキャンは表示を止めない
    @Test func pausesJudgement() {
        #expect(Exclusion.warmup.pausesJudgement)
        #expect(Exclusion.speedTest.pausesJudgement)
        #expect(Exclusion.loadTest.pausesJudgement)
        #expect(!Exclusion.lanScan.pausesJudgement)
        #expect(!Exclusion.wifiScan.pausesJudgement)
    }

    /// スリープなどで秒が大きく空いたら、1分の集計をそこで区切る（#48）
    @Test func breaksMinuteAcrossAGap() {
        func at(_ s: Double) -> Date { Self.start.addingTimeInterval(s) }
        #expect(!Monitor.breaksMinute(after: nil, next: at(0)))
        #expect(!Monitor.breaksMinute(after: at(0), next: at(1)))
        #expect(!Monitor.breaksMinute(after: at(0), next: at(Monitor.maxTickGap)))
        #expect(Monitor.breaksMinute(after: at(0), next: at(Monitor.maxTickGap + 1)))
        #expect(Monitor.breaksMinute(after: at(0), next: at(36 * 60)))
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
        // 周辺の Wi-Fi のスキャンは終わって約1秒は遅延が高いまま残る
        #expect(m.mark(.wifiScan, at: at(60)) == .wifiScan)
        #expect(m.mark(nil, at: at(61)) == .wifiScan)
        #expect(m.mark(nil, at: at(60 + SelfLoadMarker.tail)) == nil)
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

struct NetworkSwitchTests {
    static func env(gateway: String, mac: String = "") -> NetworkEnvironment {
        var e = NetworkEnvironment()
        e.gateway = gateway
        e.routerMAC = mac
        return e
    }

    @Test func staysOnTheSameNetwork() {
        #expect(Monitor.transition(from: "aa:aa:aa:aa:aa:01", to: Self.env(gateway: "192.168.1.1", mac: "aa:aa:aa:aa:aa:01")) == .stay)
    }

    /// 切断中（ゲートウェイが無い）は区切らない
    @Test func staysWhileDisconnected() {
        #expect(Monitor.transition(from: "aa:aa:aa:aa:aa:01", to: NetworkEnvironment()) == .stay)
    }

    /// `ip:…` だったネットワークのルーターの MAC が後から取れたら、同じネットワークとして続ける
    @Test func identifiesTheRouterLater() {
        #expect(Monitor.transition(from: "ip:192.168.1.1", to: Self.env(gateway: "192.168.1.1", mac: "aa:aa:aa:aa:aa:01"))
                == .identified("aa:aa:aa:aa:aa:01"))
    }

    @Test func switchesToAnotherNetwork() {
        #expect(Monitor.transition(from: "aa:aa:aa:aa:aa:01", to: Self.env(gateway: "10.0.0.1", mac: "bb:bb:bb:bb:bb:02"))
                == .switched("bb:bb:bb:bb:bb:02"))
        // ゲートウェイが違えば `ip:…` からでも別のネットワーク
        #expect(Monitor.transition(from: "ip:192.168.1.1", to: Self.env(gateway: "10.0.0.1")) == .switched("ip:10.0.0.1"))
        #expect(Monitor.transition(from: nil, to: Self.env(gateway: "10.0.0.1")) == .switched("ip:10.0.0.1"))
    }

    /// ARP が一時的に引けなくても、ゲートウェイが同じならルーターの MAC を引き継ぐ（別のネットワークと見なさない）
    @Test func carriesTheRouterMACWhenARPBlinks() {
        let old = Self.env(gateway: "192.168.1.1", mac: "aa:aa:aa:aa:aa:01")
        let blink = Monitor.carryRouterMAC(Self.env(gateway: "192.168.1.1"), from: old)
        #expect(blink.routerMAC == "aa:aa:aa:aa:aa:01")
        #expect(Monitor.transition(from: "aa:aa:aa:aa:aa:01", to: blink) == .stay)
        // ゲートウェイが変わったら引き継がない
        #expect(Monitor.carryRouterMAC(Self.env(gateway: "10.0.0.1"), from: old).routerMAC.isEmpty)
    }

    /// 変化に気づいた時点より前は前のネットワークの分として書き出し、10秒未満の切れ端は捨てる
    @Test func splitsTheMinuteAtTheBoundary() throws {
        let ticks = (0..<40).map { ExclusionTests.tick($0, gw: 8) }
        let boundary = ExclusionTests.start.addingTimeInterval(25)
        let (before, after) = Monitor.split(ticks, at: boundary)
        #expect(before.count == 25)
        #expect(after.count == 15)
        #expect(after.first?.date == boundary)
        let row = try #require(Monitor.minuteRow(before, network: "old"))
        #expect(row.net == "old")
        #expect(row.n == 25)

        let (short, _) = Monitor.split(ticks, at: ExclusionTests.start.addingTimeInterval(9))
        #expect(Monitor.minuteRow(short, network: "old") == nil)
    }
}

struct SSIDRecordingTests {
    static let home = KnownNetwork(id: "aa:aa:aa:aa:aa:01", ssid: "Home", gateway: "192.168.1.1", first: 0)
    static let unnamed = KnownNetwork(id: "aa:aa:aa:aa:aa:01", gateway: "192.168.1.1", first: 0)

    /// 切り替えの途中で新しい SSID が見えても、前のネットワークの SSID は上書きしない（#36）
    @Test func neverOverwrites() {
        #expect(!Monitor.shouldRecordSSID("iPhone", into: Self.home, gateway: "192.168.1.1", resolvingPath: false))
    }

    /// SSID が後から取れたら入れる（位置情報の許可など）
    @Test func fillsAMissingSSID() {
        #expect(Monitor.shouldRecordSSID("Home", into: Self.unnamed, gateway: "192.168.1.1", resolvingPath: false))
        var empty = Self.unnamed
        empty.ssid = ""
        #expect(Monitor.shouldRecordSSID("Home", into: empty, gateway: "192.168.1.1", resolvingPath: false))
    }

    /// 切れている間・経路の変化を処理している間は入れない（`network` がまだ前のネットワークのことがある）
    @Test func waitsWhileSwitching() {
        #expect(!Monitor.shouldRecordSSID("iPhone", into: Self.unnamed, gateway: "", resolvingPath: false))
        #expect(!Monitor.shouldRecordSSID("iPhone", into: Self.unnamed, gateway: "192.168.1.1", resolvingPath: true))
        #expect(!Monitor.shouldRecordSSID("", into: Self.unnamed, gateway: "192.168.1.1", resolvingPath: false))
        #expect(!Monitor.shouldRecordSSID("Home", into: nil, gateway: "192.168.1.1", resolvingPath: false))
    }
}

struct SerialTaskTests {
    /// やり直しを続けても、前の処理が止まり切るまで次は始まらない（PR #10 のクラッシュの再発防止）
    @Test func neverOverlaps() async {
        let loop = SerialTask()
        var active = 0, maxActive = 0
        var order: [Int] = []
        for i in 0..<5 {
            loop.restart {
                active += 1
                maxActive = max(maxActive, active)
                // 止められても await の後ろは走る（DeviceScanner の registry への書き込みと同じ）
                for _ in 0..<5 { await Task.yield() }
                order.append(i)
                active -= 1
            }
        }
        await loop.wait()
        #expect(maxActive == 1)
        #expect(order == [0, 1, 2, 3, 4])
    }
}

struct GatewayProbeTests {
    static let silent = Pinger.Batch(rtts: [], lost: 5)
    static let internet = Pinger.Batch(rtts: [30, 31])

    /// テザリング: ルーター宛ては一度も返らず、インターネット宛ては返る → 応答しないとみなす（#35）
    @Test func silentGateway() {
        var p = GatewayProbe()
        for _ in 0..<4 { p.record(gw: Self.silent, internet: Self.internet) }
        #expect(!p.isSilent)  // まだ20発
        p.record(gw: Self.silent, internet: Self.internet)
        #expect(p.isSilent)
    }

    /// 一度でも返ったルーターの途切れは本当のロス
    @Test func answeredOnceMeansRealLoss() {
        var p = GatewayProbe()
        p.record(gw: .init(rtts: [8], lost: 4), internet: Self.internet)
        for _ in 0..<10 { p.record(gw: Self.silent, internet: Self.internet) }
        #expect(!p.isSilent)
    }

    /// インターネット宛ても返らないなら、つながっていない（ロスのまま）
    @Test func everythingLostIsNotSilence() {
        var p = GatewayProbe()
        for _ in 0..<10 { p.record(gw: Self.silent, internet: .init(rtts: [], lost: 2)) }
        #expect(!p.isSilent)
    }

    /// 外した秒はルーター宛てのロスを数えず、スコアはインターネット宛てと電波だけで出る
    @Test func strippedTicksDoNotCountAsLoss() throws {
        let ticks = (0..<30).map { i in
            GatewayProbe.stripping(Tick(date: ExclusionTests.start.addingTimeInterval(Double(i)), link: nil,
                                        gw: Self.silent, v4: Self.internet, v6: .init(), rx: 0, tx: 0))
        }
        let w = Monitor.windowStats(ticks, seconds: 30)
        #expect(w.gw.n == 0 && w.gw.lost == 0)
        #expect(w.worstLoss == 0)
        #expect(Analysis.score(w, link: nil) == 100)
        #expect(Analysis.bottleneck(w, link: nil).level == .good)
        let row = try #require(Monitor.minuteRow(ticks, network: "ip:192.0.0.1"))
        #expect(row.lgw == nil)
    }

    /// 返ったものが入っている秒はそのまま
    @Test func strippingKeepsReplies() {
        let t = Tick(date: ExclusionTests.start, link: nil, gw: .init(rtts: [8], lost: 1), v4: Self.internet, v6: .init(), rx: 0, tx: 0)
        #expect(GatewayProbe.stripping(t).gw.lost == 1)
    }

    /// #35 より前の記録（ルーター宛て 100%・遅延なし・インターネットは返った）はロスとして数えない
    @Test func oldSilentMinutesAreNotRouterLoss() {
        func row(lgw: Double?, gw50: Double?, v450: Double?) -> MinuteRow {
            MinuteRow(t: 0, hour: 0, wd: 0, n: 60, gw50: gw50, v450: v450, lgw: lgw, rx: 0, tx: 0)
        }
        #expect(row(lgw: 1, gw50: nil, v450: 33).routerLoss == nil)
        #expect(row(lgw: 1, gw50: nil, v450: nil).routerLoss == 1)  // 何も返らない = 切断
        #expect(row(lgw: 0.02, gw50: 8, v450: 12).routerLoss == 0.02)
    }
}
