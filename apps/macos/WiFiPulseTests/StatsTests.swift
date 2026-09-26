import Foundation
import Testing
@testable import WiFiPulse

struct PingStatsTests {
    @Test func summarizesSamples() {
        let s = PingStats([10, 20, 30, 40, 50], lost: 1)
        #expect(s.n == 5)
        #expect(s.lost == 1)
        #expect(s.min == 10)
        #expect(s.max == 50)
        #expect(s.p50 == 30)
        #expect(s.p95 == 50)
        #expect(s.jitter == 10)
        #expect(s.loss == 1.0 / 6)
    }

    /// ゆらぎは並べ替える前（到着順）の隣り合う差の平均
    @Test func jitterFollowsArrivalOrder() {
        #expect(PingStats([10, 30, 10], lost: 0).jitter == 20)
        #expect(PingStats([10, 10, 30], lost: 0).jitter == 10)
    }

    @Test func singleSampleHasNoJitter() {
        let s = PingStats([12], lost: 0)
        #expect(s.jitter == 0)
        #expect(s.p50 == 12)
        #expect(s.p99 == 12)
    }

    @Test func emptyInput() {
        let allLost = PingStats([], lost: 3)
        #expect(allLost.n == 0)
        #expect(allLost.p50 == nil)
        #expect(allLost.loss == 1)
        #expect(PingStats([], lost: 0).loss == nil)
        #expect(PingStats.empty.loss == nil)
    }

    @Test func roundsForStorage() {
        let s = PingStats([1.26, 2.34], lost: 0).rounded
        #expect(s.min == 1.3)
        #expect(s.max == 2.3)
    }

    @Test func medianAndPercentile() {
        #expect(median([3, 1, 2]) == 2)
        #expect(median([1, 3, 2, 4]) == 2.5)
        #expect(median([]) == nil)
        #expect(percentile([1, 2, 3, 4, 5], 0) == 1)
        #expect(percentile([1, 2, 3, 4, 5], 1) == 5)
        #expect(percentile([], 0.5) == nil)
    }
}

struct PingerTests {
    @Test(arguments: [
        ("64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.346 ms", 12.35),
        ("16 bytes from 2001:4860:4860::8888, icmp_seq=3 hlim=117 time=8.123 ms", 8.12),
        ("64 bytes from 192.168.1.1: icmp_seq=12 ttl=64 time=0.9 ms", 0.9),
    ])
    func parsesRTT(line: String, expected: Double) {
        #expect(Pinger.parseRTT(line[...]) == expected)
    }

    @Test(arguments: [
        "Request timeout for icmp_seq 3",
        "PING 1.1.1.1 (1.1.1.1): 56 data bytes",
        "--- 1.1.1.1 ping statistics ---",
        "round-trip min/avg/max/stddev = 10.1/12.2/14.3/1.0 ms",
        "",
    ])
    func ignoresOtherLines(line: String) {
        #expect(Pinger.parseRTT(line[...]) == nil)
    }
}

struct LoadTestGradeTests {
    /// 無負荷時の中央値から、負荷時の p95 がどれだけ増えたか
    @Test(arguments: [
        (0.0, "A+"), (4.9, "A+"),
        (5.0, "A"), (29.9, "A"),
        (30.0, "B"), (59.9, "B"),
        (60.0, "C"), (199.9, "C"),
        (200.0, "D"), (399.9, "D"),
        (400.0, "F"), (5000.0, "F"),
    ])
    func grade(increase: Double, letter: String) {
        #expect(LoadTest.grade(idleP50: 20, loadedP95: 20 + increase).letter == letter)
    }

    @Test func unmeasured() {
        #expect(LoadTest.grade(idleP50: nil, loadedP95: 30).letter == "?")
        #expect(LoadTest.grade(idleP50: 10, loadedP95: nil).letter == "?")
    }
}
