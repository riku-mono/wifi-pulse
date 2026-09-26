import Foundation

// 保存形式は Python 版キット（wifi_monitor.py / tools/*.py）と同じ JSON Lines。
// 保存先をキットの data/ フォルダに向ければ、tools/report.py でもそのまま読める。

/// 1分ごとの集計（minutes.jsonl）
nonisolated struct MinuteRow: Codable, Sendable, Identifiable {
    var id: Int64 { t }
    var t: Int64
    var hour: Int
    var wd: Int
    var n: Int
    var rssi: Double?
    var rate: Double?
    var gw50: Double?
    var gw95: Double?
    var v450: Double?
    var v495: Double?
    var v650: Double?
    var lgw: Double?
    var lv4: Double?
    var rx: Double
    var tx: Double
    /// ネットワークの識別子（`NetworkEnvironment.networkID`）。この項目が入る前の記録は nil
    var net: String?
    /// その1分でつながっていたアクセスポイント（位置情報の許可があるときだけ）
    var bssid: String?

    var date: Date { Date(epochMs: t) }
}

/// 速度測定（speedtests.jsonl）
nonisolated struct SpeedTestRecord: Codable, Sendable, Identifiable {
    var id: Int64 { t }
    var t: Int64
    var hour: Int
    var wd: Int
    var dl: Double
    var ul: Double
    var dl_rpm: Double?
    var ul_rpm: Double?
    var base_rtt: Double?
    var net: String?

    var date: Date { Date(epochMs: t) }
}

/// 負荷試験（loadtests.jsonl）
nonisolated struct LoadTestRecord: Codable, Sendable, Identifiable {
    struct Phase: Codable, Sendable, Hashable {
        var gw: PingStats?
        var inet: PingStats?
        var rx_mbps: Double?
        var tx_mbps: Double?
    }
    struct Verdict: Codable, Sendable, Hashable {
        var grade: String
        var inet_p95: Double?
        var gw_p95: Double?
    }

    var id: Int64 { t }
    var t: Int64
    var iface: String
    var gw: String
    var target: String
    var duration: Int
    var streams: Int
    var phases: [String: Phase]
    var verdict: [String: Verdict]?
    var worst_grade: String?
    var net: String?

    var date: Date { Date(epochMs: t) }
}

/// これまでに計測したネットワーク（networks.json に識別子をキーにした辞書で保存）
nonisolated struct KnownNetwork: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var ssid: String?
    var gateway: String
    var first: Int64

    var displayName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        // SSID が取れない（位置情報の許可が無い・有線）ときはルーターで見分ける
        if id.hasPrefix("ip:") { return String(localized: "Network at \(gateway)") }
        return String(localized: "Network at \(gateway) (router …\(String(id.suffix(5))))")
    }
}

/// レポートなどで、どのネットワークの記録を見るか
nonisolated enum NetworkFilter: Hashable, Sendable {
    case all
    /// ネットワークを記録する前の記録・接続していなかったときの記録
    case unknown
    case network(String)

    init(_ id: String?) { self = id.map(Self.network) ?? .unknown }

    func includes(_ net: String?) -> Bool {
        switch self {
        case .all: true
        case .unknown: net == nil
        case .network(let id): net == id
        }
    }
}

/// data フォルダの読み書き。
nonisolated enum DataStore {
    static let folderKey = "dataFolderPath"

    static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "WiFiPulse", directoryHint: .isDirectory)
    }

    static var folder: URL {
        if let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty {
            return URL(filePath: p, directoryHint: .isDirectory)
        }
        return defaultFolder
    }

    static let minutes = "minutes.jsonl"
    static let speedtests = "speedtests.jsonl"
    static let loadtests = "loadtests.jsonl"
    static let devices = "devices.json"
    static let deviceNames = "device_names.json"
    static let networks = "networks.json"

    static func url(_ name: String) -> URL { folder.appending(path: name) }

    static func load<T: Decodable>(_ name: String, as: T.Type) -> [T] {
        guard let text = try? String(contentsOf: url(name), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    static func append<T: Encodable>(_ row: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(row) else { return }
        data.append(0x0A)
        let u = url(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: u) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: u)
        }
    }

    static func readJSON<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func writeJSON<T: Encodable>(_ value: T, to name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { try? data.write(to: url(name), options: .atomic) }
    }

    /// 計測記録を消す（OUI表などアプリ同梱のものには触らない）。
    static func deleteRecords() {
        for name in [minutes, speedtests, loadtests, devices, deviceNames, networks] {
            try? FileManager.default.removeItem(at: url(name))
        }
    }
}
