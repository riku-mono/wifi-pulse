import CoreLocation
import CoreWLAN
import Foundation

/// CoreWLAN から取るリンク情報（1秒ごと）。
nonisolated struct LinkSample: Hashable, Sendable {
    var powerOn: Bool
    var rssi: Int
    var noise: Int
    var txRate: Double
    var txPower: Int
    var phy: String
    var channel: Int?
    var band: String?
    var width: Int?
    var ssid: String?
    var bssid: String?

    var snr: Int { rssi - noise }

    /// 日本の5GHz帯: W52(36-48)はDFS無し、W53(52-64)/W56(100-144)はレーダー検出で最大60秒止まる。
    var isDFS: Bool {
        guard band == "5", let ch = channel else { return false }
        return (52...64).contains(ch) || (100...144).contains(ch)
    }

    var bandLabel: String { band.map { "\($0) GHz" } ?? "—" }
    var channelLabel: String {
        guard let channel else { return "—" }
        return "\(channel)" + (width.map { $0 > 0 ? " / \($0) MHz" : "" } ?? "")
    }

    var bars: Int {
        rssi >= -55 ? 4 : rssi >= -65 ? 3 : rssi >= -72 ? 2 : rssi >= -80 ? 1 : 0
    }

    var strengthWord: String {
        rssi >= -55 ? String(localized: "very strong") : rssi >= -65 ? String(localized: "strong") : rssi >= -72 ? String(localized: "fair") : rssi >= -80 ? String(localized: "weak") : String(localized: "very weak")
    }
}

nonisolated struct NeighborNetwork: Identifiable, Hashable, Sendable {
    var id: String { "\(bssid ?? ssid ?? "?")-\(channel)" }
    var ssid: String?
    var bssid: String?
    var channel: Int
    var band: String
    var width: Int
    var rssi: Int
    var noise: Int
}

nonisolated struct ScanResult: Sendable {
    var date: Date
    var duration: TimeInterval
    var networks: [NeighborNetwork]
    var error: String?
}

nonisolated enum WiFiLink {
    static func sample() -> LinkSample? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        var s = LinkSample(
            powerOn: iface.powerOn(),
            rssi: iface.rssiValue(),
            noise: iface.noiseMeasurement(),
            txRate: iface.transmitRate(),
            txPower: iface.transmitPower(),
            phy: phyName(iface.activePHYMode()),
            ssid: iface.ssid(),
            bssid: iface.bssid()
        )
        if let ch = iface.wlanChannel() {
            s.channel = ch.channelNumber
            s.band = bandName(ch.channelBand)
            s.width = widthMHz(ch.channelWidth)
        }
        return s
    }

    /// 近隣APのスキャン。数秒ブロックし、その間は自分の通信も数百ms止まるので乱用しない。
    static func scan() async -> ScanResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                guard let iface = CWWiFiClient.shared().interface() else {
                    cont.resume(returning: ScanResult(date: started, duration: 0, networks: [], error: String(localized: "No Wi-Fi interface found")))
                    return
                }
                do {
                    let nets = try iface.scanForNetworks(withSSID: nil)
                    let list: [NeighborNetwork] = nets.compactMap { n in
                        guard let ch = n.wlanChannel else { return nil }
                        return NeighborNetwork(ssid: n.ssid, bssid: n.bssid, channel: ch.channelNumber,
                                               band: bandName(ch.channelBand), width: widthMHz(ch.channelWidth),
                                               rssi: n.rssiValue, noise: n.noiseMeasurement)
                    }
                    cont.resume(returning: ScanResult(date: started, duration: Date().timeIntervalSince(started),
                                                      networks: list.sorted { $0.rssi > $1.rssi }))
                } catch {
                    cont.resume(returning: ScanResult(date: started, duration: Date().timeIntervalSince(started),
                                                      networks: [], error: error.localizedDescription))
                }
            }
        }
    }

    static func phyName(_ m: CWPHYMode) -> String {
        switch m {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "Wi-Fi 4 (11n)"
        case .mode11ac: "Wi-Fi 5 (11ac)"
        case .mode11ax: "Wi-Fi 6 (11ax)"
        case .mode11be: "Wi-Fi 7 (11be)"
        case .modeNone: "—"
        @unknown default: "phy\(m.rawValue)"
        }
    }

    static func widthMHz(_ w: CWChannelWidth) -> Int {
        switch w {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: 0
        }
    }

    static func bandName(_ b: CWChannelBand) -> String {
        switch b {
        case .band2GHz: "2.4"
        case .band5GHz: "5"
        case .band6GHz: "6"
        default: "?"
        }
    }
}

/// macOS は位置情報の許可が無いと SSID / BSSID を返さない。そのための許可管理。
@Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool { status == .authorizedAlways || status == .authorized }

    var statusText: String {
        switch status {
        case .notDetermined: String(localized: "Not Determined")
        case .restricted: String(localized: "Restricted")
        case .denied: String(localized: "Denied")
        case .authorizedAlways, .authorized: String(localized: "Allowed")
        default: String(localized: "Unknown")
        }
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }
}
