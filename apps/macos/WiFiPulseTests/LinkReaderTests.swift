import Foundation
import Testing
@testable import WiFiPulse

struct LinkReaderTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func link(rssi: Int = -55, powerOn: Bool = true) -> LinkSample {
        LinkSample(powerOn: powerOn, rssi: rssi, noise: -92, txRate: 864, txPower: 100, phy: "Wi-Fi 6 (11ax)",
                   channel: 36, band: "5", width: 80, ssid: "Home", bssid: "02:00:00:00:00:01")
    }

    /// 滅多に変わらない項目は `refreshInterval` のあいだ前回の値を使う
    @Test func reusesTheCacheUntilItExpires() {
        let cached = Self.link()
        #expect(!LinkReader.needsFullRead(cached: cached, fetchedAt: Self.start, now: Self.start.addingTimeInterval(1), rssi: -60))
        #expect(!LinkReader.needsFullRead(cached: cached, fetchedAt: Self.start, now: Self.start.addingTimeInterval(LinkReader.refreshInterval - 0.1), rssi: -60))
        #expect(LinkReader.needsFullRead(cached: cached, fetchedAt: Self.start, now: Self.start.addingTimeInterval(LinkReader.refreshInterval), rssi: -60))
        // 時計が戻ったとき（`invalidate` の後は distantPast なので期限切れになる）
        #expect(LinkReader.needsFullRead(cached: cached, fetchedAt: Self.start, now: Self.start.addingTimeInterval(-1), rssi: -60))
        #expect(LinkReader.needsFullRead(cached: cached, fetchedAt: .distantPast, now: Self.start, rssi: -60))
    }

    /// つながった・切れたことが RSSI でわかったら、通知を待たずに取り直す
    @Test func rereadsWhenTheLinkComesOrGoes() {
        let t = Self.start.addingTimeInterval(1)
        #expect(LinkReader.needsFullRead(cached: Self.link(), fetchedAt: Self.start, now: t, rssi: 0))
        #expect(LinkReader.needsFullRead(cached: Self.link(rssi: 0), fetchedAt: Self.start, now: t, rssi: -60))
        #expect(LinkReader.needsFullRead(cached: Self.link(powerOn: false), fetchedAt: Self.start, now: t, rssi: -60))
        #expect(!LinkReader.needsFullRead(cached: Self.link(rssi: 0), fetchedAt: Self.start, now: t, rssi: 0))
    }
}
