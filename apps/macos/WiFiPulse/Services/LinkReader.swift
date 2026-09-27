import CoreWLAN
import Foundation

/// 毎秒の `LinkSample` を読む。CoreWLAN の問い合わせは1項目ごとに Wi-Fi のデーモン（airportd）と XPC で
/// やり取りするので、毎秒変わる RSSI・ノイズ・送信レートだけを毎秒取り、滅多に変わらない項目
/// （SSID・BSSID・チャンネル・規格・送信電力・電源）は変化の通知か `refreshInterval` ごとに取り直す（#47）。
nonisolated final class LinkReader: NSObject, CWEventDelegate, @unchecked Sendable {
    static let shared = LinkReader()
    /// 変化の通知が来なくても取り直す間隔（チャンネルの変更には通知が無い）
    static let refreshInterval: TimeInterval = 10

    private let lock = NSLock()
    /// 前回まとめて取った値（滅多に変わらない項目はここから使う）
    private var cached: LinkSample?
    private var fetchedAt = Date.distantPast

    private override init() {
        super.init()
        let client = CWWiFiClient.shared()
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .bssidDidChange, .linkDidChange, .powerDidChange, .modeDidChange] {
            try? client.startMonitoringEvent(with: event)
        }
    }

    /// 次の読み取りで全項目を取り直す（経路が変わったときなど）
    func invalidate() {
        lock.withLock { fetchedAt = .distantPast }
    }

    func sample(at now: Date = Date()) -> LinkSample? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        let rssi = iface.rssiValue()
        let (cached, fetchedAt) = lock.withLock { (self.cached, self.fetchedAt) }
        guard let cached, !Self.needsFullRead(cached: cached, fetchedAt: fetchedAt, now: now, rssi: rssi) else {
            let full = WiFiLink.sample(iface)
            lock.withLock {
                self.cached = full
                self.fetchedAt = now
            }
            return full
        }
        var s = cached
        s.rssi = rssi
        s.noise = iface.noiseMeasurement()
        s.txRate = iface.transmitRate()
        return s
    }

    /// 全項目を取り直すか。期限切れのほか、つながっているはずなのに RSSI が 0（切れた）ときや、
    /// 切れているはずなのに RSSI が出た（つながった）ときは、通知を待たずに取り直す
    static func needsFullRead(cached: LinkSample, fetchedAt: Date, now: Date, rssi: Int) -> Bool {
        if now.timeIntervalSince(fetchedAt) >= refreshInterval || now < fetchedAt { return true }
        let wasLinked = cached.powerOn && cached.rssi != 0
        return wasLinked != (rssi != 0)
    }

    // MARK: CWEventDelegate（CoreWLAN の内部のキューから呼ばれる）

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { invalidate() }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { invalidate() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { invalidate() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { invalidate() }
    func modeDidChangeForWiFiInterface(withName interfaceName: String) { invalidate() }
}
