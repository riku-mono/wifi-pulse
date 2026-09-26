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
            case .disconnect: String(localized: "Disconnects")
            case .roam: String(localized: "Roaming")
            case .scan: String(localized: "Scan Requests")
            case .dfs: String(localized: "Radar / Channel Change")
            case .awdl: "AWDL"
            case .btcoex: String(localized: "Bluetooth Coexistence")
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
                String(localized: "Even a single disconnect stops traffic for several seconds. Reason codes: 3 = leaving, 4 = inactivity timeout, 8 = disconnected by the access point.")
            case .roam:
                String(localized: "With mesh systems or extenders, devices can bounce between access points, causing repeated 1–3 second dropouts.")
            case .scan:
                String(localized: "During a scan the radio leaves your channel, pausing traffic for a few hundred milliseconds each time. Many from locationd means Location Services; sharingd means AirDrop discovery.")
            case .dfs:
                String(localized: "If this appears on a 5 GHz W53/W56 channel, it is almost certainly the cause. Fixing your router to W52 (channels 36/40/44/48) stops it.")
            case .awdl:
                String(localized: "Traffic for AirDrop, AirPlay, Handoff, and Sidecar. The Wi-Fi chip periodically hops to another channel, causing regular latency spikes.")
            case .btcoex:
                String(localized: "Records of sharing 2.4 GHz airtime with Bluetooth devices. If there are many, moving to 5 GHz may help.")
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
            case .h1: String(localized: "1 hour")
            case .h2: String(localized: "2 hours")
            case .h6: String(localized: "6 hours")
            case .h24: String(localized: "24 hours")
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
