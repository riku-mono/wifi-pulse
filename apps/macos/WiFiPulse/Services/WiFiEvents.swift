import Foundation
import Observation

/// macOS の統合ログから「遅延スパイクの犯人」になりうる Wi-Fi イベントを抜き出す。
@Observable
final class WiFiEvents {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case disconnect, roam, scan, dfs, awdl, btcoex
        var id: Self { self }

        var title: String {
            switch self {
            case .disconnect: "切断・再接続"
            case .roam: "ローミング"
            case .scan: "スキャン要求"
            case .dfs: "レーダー / チャンネル変更"
            case .awdl: "AWDL"
            case .btcoex: "Bluetooth共存"
            }
        }

        var symbol: String {
            switch self {
            case .disconnect: "wifi.slash"
            case .roam: "arrow.triangle.swap"
            case .scan: "dot.radiowaves.left.and.right"
            case .dfs: "dot.scope"
            case .awdl: "airplayaudio"
            case .btcoex: "wave.3.right"
            }
        }

        var explanation: String {
            switch self {
            case .disconnect:
                "切断が1回でもあれば、その瞬間の通信は数秒止まります。reason code 3=離脱, 4=無通信タイムアウト, 8=AP側から切断。"
            case .roam:
                "メッシュや中継器があると、端末が行ったり来たりして1〜3秒の断が繰り返し起きます。"
            case .scan:
                "スキャン中はチャンネルを離れるので、1回あたり数百ms通信が止まります。locationd が多ければ位置情報サービス、sharingd なら AirDrop の相手探索です。"
            case .dfs:
                "5GHz の W53/W56 でこれが出るなら原因はほぼ確定。ルーターのチャンネルを W52（36/40/44/48ch）に固定すれば止まります。"
            case .awdl:
                "AirDrop・AirPlay・Handoff・Sidecar 用の通信。Wi-Fi チップが定期的に別チャンネルへ出張するため、周期的なスパイクが出ます。"
            case .btcoex:
                "2.4GHz 帯で Bluetooth 機器と電波を分け合っている記録。多ければ 5GHz に寄せると改善することがあります。"
            }
        }
    }

    struct Bucket: Identifiable, Sendable {
        var id: String { "\(category.rawValue)-\(start.timeIntervalSince1970)" }
        let start: Date
        let category: Category
        let count: Int
    }

    struct Report: Sendable {
        var span: String
        var generated: Date
        var lineCount: Int
        var counts: [Category: Int]
        var liveScans: Int
        var buckets: [Bucket]
        var requesters: [(name: String, count: Int)]
        var samples: [Category: [String]]
        var awdlState: String
    }

    enum Span: String, CaseIterable, Identifiable {
        case h1 = "1h", h2 = "2h", h6 = "6h", h24 = "24h"
        var id: Self { self }
        var label: String {
            switch self {
            case .h1: "1時間"
            case .h2: "2時間"
            case .h6: "6時間"
            case .h24: "24時間"
            }
        }
    }

    var span: Span = .h2
    private(set) var isLoading = false
    private(set) var report: Report?

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        let s = span.rawValue
        report = await Task.detached(priority: .userInitiated) { await Self.collect(span: s) }.value
        isLoading = false
    }

    nonisolated static func collect(span: String) async -> Report {
        let text = await Shell.run("/usr/bin/log", [
            "show", "--last", span, "--style", "compact",
            "--predicate", #"process == "airportd" OR process == "wifid" OR subsystem BEGINSWITH "com.apple.wifi""#,
        ], timeout: 120)
        let awdl = await Shell.run("/sbin/ifconfig", ["awdl0"])
            .split(separator: "\n").prefix(2).joined(separator: "\n")

        let noise = ["auto-join", "bsslist", "known network", "cwchannel:", "channelwidth=", "supportedchannels"]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"

        var counts: [Category: Int] = [:]
        var samples: [Category: [String]] = [:]
        var bucketCounts: [Date: [Category: Int]] = [:]
        var requesters: [String: Int] = [:]
        var liveScans = 0
        var lines = 0

        for raw in text.split(separator: "\n") {
            lines += 1
            let line = raw.lowercased()
            var hits: [Category] = []
            let isNoise = noise.contains { line.contains($0) }
            if !isNoise, ["disassoc", "deauth", "link down", "link_down", "connection lost"].contains(where: { line.contains($0) }) {
                hits.append(.disconnect)
            }
            if raw.contains("Roam:") { hits.append(.roam) }
            if raw.contains("SCAN request received") {
                hits.append(.scan)
                if let m = raw.firstMatch(of: #/SCAN request received from pid \d+ \(([^)]+)\)/#) {
                    requesters[String(m.1), default: 0] += 1
                }
            }
            if raw.contains("live scan") { liveScans += 1 }
            if !isNoise, line.contains("radar") || line.contains("channel switch") || line.contains("switching to channel")
                || line.contains("csa received") || line.firstMatch(of: #/dfs (event|detect|state)/#) != nil {
                hits.append(.dfs)
            }
            if line.contains("awdl") { hits.append(.awdl) }
            if line.contains("btcoex") || line.contains("bt coex") || line.contains("bt_coex") { hits.append(.btcoex) }
            guard !hits.isEmpty else { continue }

            var bucket: Date?
            if raw.count >= 16, let d = fmt.date(from: String(raw.prefix(16))) {
                let t = d.timeIntervalSince1970
                bucket = Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: 600))
            }
            for c in hits {
                counts[c, default: 0] += 1
                if samples[c, default: []].count < 20 { samples[c, default: []].append(String(raw.prefix(220))) }
                if let bucket { bucketCounts[bucket, default: [:]][c, default: 0] += 1 }
            }
        }

        let buckets = bucketCounts.flatMap { start, m in m.map { Bucket(start: start, category: $0.key, count: $0.value) } }
            .sorted { $0.start < $1.start }
        return Report(span: span, generated: Date(), lineCount: lines, counts: counts, liveScans: liveScans,
                      buckets: buckets,
                      requesters: requesters.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) },
                      samples: samples, awdlState: awdl)
    }
}
