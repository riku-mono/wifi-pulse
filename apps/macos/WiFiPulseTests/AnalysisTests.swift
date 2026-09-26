import Foundation
import Testing
@testable import WiFiPulse

// 文言は表示言語で変わるので比較しない。段階（Level）・区間・件数・深刻度で確かめる

func linkSample(rssi: Int) -> LinkSample {
    LinkSample(powerOn: true, rssi: rssi, noise: -95, txRate: 866, txPower: 20, phy: "11ac",
               channel: 36, band: "5", width: 80, ssid: nil, bssid: nil)
}

func window(gw: PingStats = .empty, v4: PingStats = .empty) -> WindowStats {
    WindowStats(seconds: 30, gw: gw, v4: v4, v6: .empty)
}

struct AnalysisTests {
    static let healthy = window(gw: PingStats(n: 30, lost: 0, p50: 2, p95: 5), v4: PingStats(n: 30, lost: 0, p50: 15, p95: 20, jitter: 1))

    @Test func scoreNeedsData() {
        #expect(Analysis.score(window(), link: nil) == nil)
        #expect(Analysis.verdict(nil).1 == .none)
    }

    @Test func perfectAndWorstScores() {
        #expect(Analysis.score(Self.healthy, link: linkSample(rssi: -50)) == 100)
        let bad = window(gw: PingStats(n: 20, lost: 10, p95: 200), v4: PingStats(n: 20, lost: 10, p95: 500, jitter: 100))
        #expect(Analysis.score(bad, link: linkSample(rssi: -90)) == 0)
    }

    /// 電波が取れない（有線など）ときは、残りの項目だけで重みを割り直す
    @Test func scoreWithoutLink() {
        #expect(Analysis.score(Self.healthy, link: nil) == 100)
    }

    @Test(arguments: [
        (100, Level.good), (85, .good), (84, .good), (65, .good),
        (64, .warn), (40, .warn),
        (39, .crit), (0, .crit),
    ])
    func verdictLevel(score: Int, level: Level) {
        #expect(Analysis.verdict(score).1 == level)
    }

    @Test func bottleneckWhileCollecting() {
        let b = Analysis.bottleneck(window(), link: nil)
        #expect(b.level == .none)
        #expect(b.segment == nil)
    }

    @Test func bottleneckWeakSignal() {
        let b = Analysis.bottleneck(Self.healthy, link: linkSample(rssi: -75))
        #expect(b.level == .crit)
        #expect(b.segment == .wifi)
        #expect(Analysis.bottleneck(Self.healthy, link: linkSample(rssi: -74)).level == .good)
    }

    @Test func bottleneckOnTheWiFiSegment() {
        let slowRouter = window(gw: PingStats(n: 30, lost: 0, p95: 31), v4: PingStats(n: 30, lost: 0, p95: 40))
        #expect(Analysis.bottleneck(slowRouter, link: nil).segment == .wifi)
        let lossyRouter = window(gw: PingStats(n: 98, lost: 2, p95: 5), v4: PingStats(n: 30, lost: 0, p95: 20))
        #expect(Analysis.bottleneck(lossyRouter, link: nil).segment == .wifi)
    }

    @Test func bottleneckOnTheInternetLine() {
        let slowWAN = window(gw: PingStats(n: 30, lost: 0, p95: 5), v4: PingStats(n: 30, lost: 0, p95: 56))
        let b = Analysis.bottleneck(slowWAN, link: nil)
        #expect(b.level == .warn)
        #expect(b.segment == .wan)
        // 差がちょうど 50ms なら問題なし
        let edge = window(gw: PingStats(n: 30, lost: 0, p95: 5), v4: PingStats(n: 30, lost: 0, p95: 55))
        #expect(Analysis.bottleneck(edge, link: nil).level == .good)
    }

    @Test func noBottleneck() {
        let b = Analysis.bottleneck(Self.healthy, link: linkSample(rssi: -50))
        #expect(b.level == .good)
        #expect(b.segment == nil)
    }
}

struct ReportTests {
    static func minute(hour: Int, wd: Int = 0, gw50: Double? = 2, gw95: Double? = 5, v450: Double? = 15, v495: Double? = 25,
                       lgw: Double? = 0, lv4: Double? = 0, rssi: Double? = -50) -> MinuteRow {
        MinuteRow(t: 0, hour: hour, wd: wd, n: 60, rssi: rssi, rate: nil, gw50: gw50, gw95: gw95, v450: v450, v495: v495,
                  v650: nil, lgw: lgw, lv4: lv4, rx: 0, tx: 0, net: nil, bssid: nil)
    }

    static func speed(hour: Int, dl: Double, dlRPM: Double? = nil) -> SpeedTestRecord {
        SpeedTestRecord(t: 0, hour: hour, wd: 0, dl: dl, ul: 10, dl_rpm: dlRPM, ul_rpm: nil, base_rtt: nil, net: nil)
    }

    static func loadTest(grade: String) -> LoadTestRecord {
        LoadTestRecord(t: 0, iface: "en0", gw: "192.168.1.1", target: "1.1.1.1", duration: 10, streams: 4,
                       phases: [:], verdict: nil, worst_grade: grade, net: nil)
    }

    @Test func hourlyGroupsByHourAndDay() {
        let r = RecordSet(minutes: [
            Self.minute(hour: 3, wd: 0, v450: 10),
            Self.minute(hour: 3, wd: 1, v450: 20),
            Self.minute(hour: 3, wd: 6, v450: 90),  // 日曜
            Self.minute(hour: 24, wd: 0),           // 範囲外は無視
        ], speed: [Self.speed(hour: 3, dl: 100), Self.speed(hour: 4, dl: 50)])

        let all = Report.hourly(r, filter: .all)
        #expect(all.count == 24)
        #expect(all[3].minutes == 3)
        #expect(all[3].v4 == 20)
        #expect(all[3].speedTests == 1)
        #expect(all[4].dl == 50)

        let weekday = Report.hourly(r, filter: .weekday)
        #expect(weekday[3].minutes == 2)
        #expect(weekday[3].v4 == 15)
        #expect(Report.hourly(r, filter: .weekend)[3].minutes == 1)
        #expect(all.reduce(0) { $0 + $1.minutes } == 3)
    }

    func findings(_ r: RecordSet) -> [Finding] {
        Report.findings(r, hourly: Report.hourly(r, filter: .all))
    }

    @Test func nothingToReportWhenHealthy() {
        let r = RecordSet(minutes: (0..<24).map { Self.minute(hour: $0) })
        #expect(findings(r).isEmpty)
        #expect(findings(RecordSet()).isEmpty)
    }

    @Test func slowWiFiSegment() {
        let r = RecordSet(minutes: [Self.minute(hour: 1, gw50: 15)])
        #expect(findings(r).map(\.severity) == [3])
    }

    @Test func peakHourSlowdown() {
        let r = RecordSet(minutes: [1, 2, 3].map { Self.minute(hour: $0, v450: 10) } + [Self.minute(hour: 21, v450: 60)])
        #expect(findings(r).map(\.severity) == [2])
    }

    @Test func weakSignal() {
        #expect(findings(RecordSet(minutes: [Self.minute(hour: 1, rssi: -70)])).map(\.severity) == [3])
        #expect(findings(RecordSet(minutes: [Self.minute(hour: 1, rssi: -65)])).map(\.severity) == [1])
    }

    @Test func mostSevereFirst() {
        let r = RecordSet(minutes: [Self.minute(hour: 1, rssi: -65)], loads: [Self.loadTest(grade: "F")])
        #expect(findings(r).map(\.severity) == [4, 1])
    }

    @Test func mildBufferbloat() {
        #expect(findings(RecordSet(loads: [Self.loadTest(grade: "C")])).map(\.severity) == [2])
        #expect(findings(RecordSet(loads: [Self.loadTest(grade: "A")])).isEmpty)
    }

    @Test func speedTests() {
        #expect(findings(RecordSet(speed: [Self.speed(hour: 1, dl: 100, dlRPM: 200)])).map(\.severity) == [4])
        let varied = [100.0, 90, 20].map { Self.speed(hour: 1, dl: $0) }
        #expect(findings(RecordSet(speed: varied)).map(\.severity) == [2])
    }
}
