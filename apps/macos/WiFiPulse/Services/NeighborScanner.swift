import CoreWLAN
import Foundation
import Observation

/// 周辺のアクセスポイント1台。
nonisolated struct AccessPoint: Identifiable, Hashable, Sendable {
    let id: String
    var ssid: String?
    var bssid: String?
    var band: Band
    /// プライマリチャンネル
    var channel: Int
    var width: Int
    /// 実際に電波を出している範囲の中心（チャンネル番号単位。40MHz以上だとプライマリとずれる）
    var center: Double
    var rssi: Int
    var noise: Int
    var security: String
    /// 暗号化なし・WEP（表示を注意色にする）
    var isInsecure: Bool
    var generation: Int?
    var beaconInterval: Int
    var country: String?
    /// BSS Load 要素（対応APのみ）: 接続中の端末数とチャンネル利用率
    var stations: Int?
    var utilization: Double?
    var vendor: String?
    var firstSeen: Date
    var lastSeen: Date
    var history: [RSSIPoint] = []

    nonisolated struct RSSIPoint: Hashable, Sendable {
        let date: Date
        let rssi: Int
    }

    /// 電波が占有しているチャンネル番号の範囲（20MHz = 4チャンネル分）
    var span: ClosedRange<Double> {
        let half = Double(max(width, 20)) / 10
        return (center - half)...(center + half)
    }

    /// 20MHzチャンネル `ch` と電波が重なるか（端が接しているだけの隣接チャンネルは含めない）
    func overlaps(channel ch: Int) -> Bool {
        span.lowerBound < Double(ch) + 2 - 0.01 && span.upperBound > Double(ch) - 2 + 0.01
    }

    var isDFS: Bool { band == .ghz5 && ((52...64).contains(channel) || (100...144).contains(channel)) }
    var isHidden: Bool { (ssid ?? "").isEmpty }
    var displayName: String { isHidden ? String(localized: "（非公開ネットワーク）") : ssid! }
    var generationLabel: String { generation.map { "Wi-Fi \($0)" } ?? "—" }

    // Table の並べ替え用（Optional は Comparable でないため）
    var sortName: String { ssid ?? "" }
    var sortGeneration: Int { generation ?? 0 }
    var sortUtilization: Double { utilization ?? -1 }
    var sortStations: Int { stations ?? -1 }
    var sortVendor: String { vendor ?? "" }
}

nonisolated enum Band: String, CaseIterable, Identifiable, Sendable, Hashable {
    case ghz24 = "2.4", ghz5 = "5", ghz6 = "6"
    var id: Self { self }
    var label: String { "\(rawValue) GHz" }

    /// チャート・混雑度の対象にするチャンネル（20MHz単位のプライマリ）
    var channels: [Int] {
        switch self {
        case .ghz24: Array(1...13)
        case .ghz5: [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144]
        case .ghz6: Array(stride(from: 1, through: 93, by: 4))
        }
    }

    /// 推奨候補。2.4GHz は重ならない 1/6/11 のみ。
    var candidates: [Int] {
        self == .ghz24 ? [1, 6, 11] : channels
    }

    func dfsLabel(_ ch: Int) -> String? {
        guard self == .ghz5 else { return nil }
        if (36...48).contains(ch) { return "W52" }
        if (52...64).contains(ch) { return "W53" }
        if (100...144).contains(ch) { return "W56" }
        if (149...177).contains(ch) { return "W58" }
        return nil
    }

    func isDFS(_ ch: Int) -> Bool { self == .ghz5 && ((52...64).contains(ch) || (100...144).contains(ch)) }
}

/// チャンネルごとの混雑度
nonisolated struct ChannelLoad: Identifiable, Hashable, Sendable {
    var id: Int { channel }
    let channel: Int
    /// 重なっているAPの影響の合計（電波が強いほど大きい）
    let score: Double
    let count: Int
    let strongest: Int?
    let isDFS: Bool
    let isMine: Bool

    var level: Level { score < 0.6 ? .good : score < 1.6 ? .warn : .crit }
}

/// 近隣APのスキャンと、その結果の蓄積・分析。
@Observable
final class NeighborScanner {
    enum AutoInterval: Int, CaseIterable, Identifiable {
        case off = 0, s30 = 30, s60 = 60, s120 = 120
        var id: Self { self }
        var label: String {
            switch self {
            case .off: String(localized: "自動スキャンしない")
            case .s30: String(localized: "30秒ごと")
            case .s60: String(localized: "1分ごと")
            case .s120: String(localized: "2分ごと")
            }
        }
    }

    private(set) var accessPoints: [AccessPoint] = []
    private(set) var lastScan: Date?
    private(set) var lastDuration: TimeInterval = 0
    private(set) var isScanning = false
    private(set) var error: String?
    private(set) var scanCount = 0

    var autoInterval: AutoInterval = .off {
        didSet { if oldValue != autoInterval { restartAuto() } }
    }

    @ObservationIgnored private var store: [String: AccessPoint] = [:]
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var lastRequest = Date.distantPast

    /// スキャン自体が数百msの通信停止を起こすので、最短15秒あける
    @discardableResult
    func scan() async -> Bool {
        guard !isScanning, Date().timeIntervalSince(lastRequest) >= 15 else { return false }
        lastRequest = Date()
        isScanning = true
        defer { isScanning = false }
        let started = Date()
        let result = await Self.performScan()
        lastDuration = Date().timeIntervalSince(started)
        switch result {
        case .failure(let e):
            error = e.localizedDescription
            return false
        case .success(let raw):
            error = nil
            await merge(raw, at: started)
            lastScan = started
            scanCount += 1
            return true
        }
    }

    /// 前回のスキャンに写っていた AP（`includeStale` なら10分以内に見えたもの）
    func visible(band: Band, includeStale: Bool) -> [AccessPoint] {
        guard let last = lastScan else { return [] }
        let cutoff = includeStale ? last.addingTimeInterval(-600) : last
        return accessPoints.filter { $0.band == band && $0.lastSeen >= cutoff }
    }

    private func restartAuto() {
        autoTask?.cancel()
        guard autoInterval != .off else { return }
        let seconds = autoInterval.rawValue
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func merge(_ raw: [RawNetwork], at date: Date) async {
        for r in raw {
            let key = r.bssid ?? "\(r.ssid ?? "?")|\(r.band.rawValue)|\(r.channel)"
            var ap = store[key] ?? AccessPoint(
                id: key, ssid: r.ssid, bssid: r.bssid, band: r.band, channel: r.channel, width: r.width,
                center: r.center, rssi: r.rssi, noise: r.noise, security: r.security, isInsecure: r.isInsecure, generation: r.generation,
                beaconInterval: r.beaconInterval, country: r.country, firstSeen: date, lastSeen: date)
            ap.ssid = r.ssid ?? ap.ssid
            ap.channel = r.channel
            ap.width = r.width
            ap.center = r.center
            ap.rssi = r.rssi
            ap.noise = r.noise
            ap.security = r.security
            ap.isInsecure = r.isInsecure
            ap.generation = r.generation ?? ap.generation
            ap.stations = r.stations
            ap.utilization = r.utilization
            ap.lastSeen = date
            ap.history.append(.init(date: date, rssi: r.rssi))
            if ap.history.count > 120 { ap.history.removeFirst(ap.history.count - 120) }
            if ap.vendor == nil, let b = r.bssid { ap.vendor = await OUI.shared.vendor(for: b) }
            store[key] = ap
        }
        // 1時間見えていないものは捨てる
        store = store.filter { date.timeIntervalSince($0.value.lastSeen) < 3600 }
        accessPoints = store.values.sorted { $0.rssi > $1.rssi }
    }

    // MARK: Analysis

    /// 各チャンネルの混雑度。自分のAP（同じSSID）は除いて数える。
    static func channelLoads(_ aps: [AccessPoint], band: Band, mySSID: String?, myChannel: Int?) -> [ChannelLoad] {
        var channels = band.channels
        for ap in aps where !channels.contains(ap.channel) { channels.append(ap.channel) }
        channels.sort()
        let others = aps.filter { mySSID == nil || $0.ssid != mySSID }
        return channels.map { ch in
            var score = 0.0, count = 0, strongest: Int?
            for ap in others where ap.overlaps(channel: ch) {
                // -95dBm で 0、-50dBm で 1 になる重み。利用率が分かれば加味する
                var w = min(1, max(0, Double(ap.rssi + 95) / 45))
                if let u = ap.utilization { w *= 0.5 + u }
                // 2.4GHz は隣接チャンネルとの部分的な重なりも干渉になるので、中心からの距離で減衰
                if band == .ghz24 { w *= max(0.2, 1 - abs(ap.center - Double(ch)) / 5) }
                score += w
                count += 1
                strongest = max(strongest ?? -200, ap.rssi)
            }
            return ChannelLoad(channel: ch, score: score, count: count, strongest: strongest,
                               isDFS: band.isDFS(ch), isMine: ch == myChannel)
        }
    }

    /// 空いている順の推奨チャンネル。同点なら DFS でない方を優先。
    static func recommendations(_ loads: [ChannelLoad], band: Band) -> [ChannelLoad] {
        loads.filter { band.candidates.contains($0.channel) }
            .sorted { ($0.score + ($0.isDFS ? 0.4 : 0), $0.channel) < ($1.score + ($1.isDFS ? 0.4 : 0), $1.channel) }
            .prefix(3)
            .map { $0 }
    }

    // MARK: Scan

    nonisolated struct RawNetwork: Sendable {
        var ssid: String?
        var bssid: String?
        var band: Band
        var channel: Int
        var width: Int
        var center: Double
        var rssi: Int
        var noise: Int
        var security: String
        var isInsecure: Bool
        var generation: Int?
        var beaconInterval: Int
        var country: String?
        var stations: Int?
        var utilization: Double?
    }

    @concurrent
    nonisolated static func performScan() async -> Result<[RawNetwork], any Error> {
        guard let iface = CWWiFiClient.shared().interface() else {
            return .failure(NSError(domain: "WiFiPulse", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Wi-Fiインターフェースが見つかりません")]))
        }
        do {
            let nets = try iface.scanForNetworks(withSSID: nil)
            return .success(nets.compactMap(Self.convert))
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func convert(_ n: CWNetwork) -> RawNetwork? {
        guard let ch = n.wlanChannel else { return nil }
        let band: Band
        switch ch.channelBand {
        case .band2GHz: band = .ghz24
        case .band5GHz: band = .ghz5
        case .band6GHz: band = .ghz6
        default: return nil
        }
        let ie = n.informationElementData.map(InformationElements.init) ?? InformationElements()
        let width = WiFiLink.widthMHz(ch.channelWidth)
        let center = ChannelGeometry.center(primary: ch.channelNumber, width: width, band: band, ie: ie)
        var gen: Int?
        if n.supportsPHYMode(.mode11be) || ie.hasEHT { gen = 7 }
        else if n.supportsPHYMode(.mode11ax) || ie.hasHE { gen = 6 }
        else if n.supportsPHYMode(.mode11ac) || ie.hasVHT { gen = 5 }
        else if n.supportsPHYMode(.mode11n) || ie.hasHT { gen = 4 }
        return RawNetwork(ssid: n.ssid, bssid: n.bssid, band: band, channel: ch.channelNumber, width: width,
                          center: center, rssi: n.rssiValue, noise: n.noiseMeasurement,
                          security: securityLabel(n), isInsecure: isInsecure(n), generation: gen, beaconInterval: n.beaconInterval,
                          country: n.countryCode, stations: ie.stationCount, utilization: ie.channelUtilization)
    }

    /// 暗号化の無いオープンネットワークと WEP。OWE は暗号化されるので含めない
    nonisolated static func isInsecure(_ n: CWNetwork) -> Bool {
        let encrypted: [CWSecurity] = [.wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal, .wpaEnterprise, .wpaEnterpriseMixed,
                                       .wpa2Enterprise, .enterprise, .wpa3Personal, .wpa3Enterprise, .wpa3Transition, .OWE, .oweTransition]
        if encrypted.contains(where: n.supportsSecurity) { return false }
        return n.supportsSecurity(.none) || n.supportsSecurity(.WEP) || n.supportsSecurity(.dynamicWEP)
    }

    nonisolated static func securityLabel(_ n: CWNetwork) -> String {
        if n.supportsSecurity(.wpa3Enterprise) { return String(localized: "WPA3 エンタープライズ") }
        if n.supportsSecurity(.wpa3Personal) && !n.supportsSecurity(.wpa2Personal) { return "WPA3" }
        if n.supportsSecurity(.wpa3Transition) || (n.supportsSecurity(.wpa3Personal) && n.supportsSecurity(.wpa2Personal)) { return "WPA2/WPA3" }
        if n.supportsSecurity(.wpa2Enterprise) || n.supportsSecurity(.enterprise) { return String(localized: "WPA2 エンタープライズ") }
        if n.supportsSecurity(.wpa2Personal) { return "WPA2" }
        if n.supportsSecurity(.wpaPersonal) || n.supportsSecurity(.wpaPersonalMixed) { return "WPA" }
        if n.supportsSecurity(.OWE) || n.supportsSecurity(.oweTransition) { return String(localized: "OWE（暗号化オープン）") }
        if n.supportsSecurity(.WEP) || n.supportsSecurity(.dynamicWEP) { return String(localized: "WEP（危険）") }
        if n.supportsSecurity(.none) { return String(localized: "なし（オープン）") }
        return String(localized: "不明")
    }
}

/// ビーコンの情報要素（IE）のうち、チャンネル幅と混雑度に関係するものだけを読む。
/// macOS は位置情報の許可が無いアプリには IE を返さないので、無い前提でも動くようにしてある。
nonisolated struct InformationElements: Sendable {
    var stationCount: Int?
    var channelUtilization: Double?
    /// HT Operation の副チャンネル位置: +1 = 上, -1 = 下
    var secondaryOffset: Int?
    var vhtWidth: Int?
    var vhtCenter0: Int?
    var vhtCenter1: Int?
    var hasHT = false
    var hasVHT = false
    var hasHE = false
    var hasEHT = false

    init() {}

    init(_ data: Data) {
        let b = [UInt8](data)
        var p = 0
        while p + 2 <= b.count {
            let id = b[p], len = Int(b[p + 1])
            let body = p + 2
            guard body + len <= b.count else { break }
            switch id {
            case 11 where len >= 5: // BSS Load
                stationCount = Int(b[body]) | Int(b[body + 1]) << 8
                channelUtilization = Double(b[body + 2]) / 255
            case 45: hasHT = true
            case 61 where len >= 2: // HT Operation
                switch b[body + 1] & 0x03 {
                case 1: secondaryOffset = 1
                case 3: secondaryOffset = -1
                default: break
                }
            case 191: hasVHT = true
            case 192 where len >= 3: // VHT Operation
                vhtWidth = Int(b[body])
                vhtCenter0 = Int(b[body + 1])
                vhtCenter1 = Int(b[body + 2])
            case 255 where len >= 1: // Element ID Extension
                switch b[body] {
                case 35: hasHE = true   // HE Capabilities
                case 108: hasEHT = true // EHT Capabilities
                default: break
                }
            default: break
            }
            p = body + len
        }
    }
}

/// プライマリチャンネルと帯域幅から、実際に使っている範囲の中心を求める。
nonisolated enum ChannelGeometry {
    static let centers5GHz40: [Int] = [38, 46, 54, 62, 102, 110, 118, 126, 134, 142, 151, 159, 167, 175]
    static let centers5GHz80: [Int] = [42, 58, 106, 122, 138, 155, 171]
    static let centers5GHz160: [Int] = [50, 114, 163]

    static func center(primary: Int, width: Int, band: Band, ie: InformationElements) -> Double {
        let p = Double(primary)
        switch (band, width) {
        case (_, ...20):
            return p
        case (.ghz24, _):
            let offset = ie.secondaryOffset ?? (primary <= 7 ? 1 : -1)
            return p + Double(offset * 2)
        case (.ghz5, 40):
            if let off = ie.secondaryOffset { return p + Double(off * 2) }
            return nearest(centers5GHz40, to: primary, within: 2) ?? p
        case (.ghz5, 80):
            if let c = ie.vhtCenter0, c > 0, (ie.vhtWidth ?? 0) >= 1 { return Double(c) }
            return nearest(centers5GHz80, to: primary, within: 6) ?? p
        case (.ghz5, _):
            if let c1 = ie.vhtCenter1, c1 > 0 { return Double(c1) }
            return nearest(centers5GHz160, to: primary, within: 14) ?? p
        case (.ghz6, _):
            // 6GHz は 1,5,9… の20MHzチャンネルを帯域幅ごとに区切った中央
            let block = width / 5  // 40→8, 80→16, 160→32, 320→64
            let start = ((primary - 1) / block) * block + 1
            return Double(start) + Double(block - 4) / 2
        }
    }

    private static func nearest(_ centers: [Int], to ch: Int, within: Int) -> Double? {
        centers.first { abs($0 - ch) <= within }.map(Double.init)
    }
}
