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
    /// 集計から除いた秒数（このアプリの速度測定・負荷試験・LAN の掃引・周辺の Wi-Fi のスキャンの間）。除いた秒が無ければ nil（項目ごと書かない）。
    /// 値はそれ以外の秒だけから出しているので、時間帯の集計にはそのまま使える
    var self_s: Int?

    var date: Date { Date(epochMs: t) }

    /// ルーター宛てのロス。ルーターが ping に応答しない（1分ずっと失われ、インターネット宛ては返った）記録は nil。
    /// #35 より前の記録には、テザリングなどでこの形の 100% が入っている
    var routerLoss: Double? {
        if lgw == 1, gw50 == nil, v450 != nil { return nil }
        return lgw
    }
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
    /// 自分で付けた名前（SSID が取れない有線・テザリングなど）
    var name: String?
    /// ほかのネットワークにまとめたときの、まとめ先の識別子。記録の `net` は書き換えず、表示と集計でまとめ先の分として扱う
    var mergedInto: String?
    /// 自分で分けたネットワーク。自動ではまとめない
    var keepSeparate: Bool?

    /// ルーターの MAC が取れずに、ゲートウェイの IP で登録したもの
    var isGatewayOnly: Bool { id.hasPrefix("ip:") }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return automaticName
    }

    /// 自分で名前を付けていないときの名前
    var automaticName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        // SSID が取れない（位置情報の許可が無い・有線）ときはルーターで見分ける
        if isGatewayOnly { return String(localized: "Network at \(gateway)") }
        return String(localized: "Network at \(gateway) (router …\(String(id.suffix(5))))")
    }
}

/// networks.json の中身（識別子 → 登録）。まとめたネットワークは、まとめ先を代表として扱う
extension Dictionary where Key == String, Value == KnownNetwork {
    /// 代表の識別子。まとめていなければ自分自身（登録の無い識別子も自分自身）
    nonisolated func canonical(_ id: String) -> String {
        var cur = id
        // まとめ先は常に代表を指すが、壊れたファイルで輪になっても止まるようにする
        for _ in 0...count {
            guard let next = self[cur]?.mergedInto, next != cur, self[next] != nil else { return cur }
            cur = next
        }
        return cur
    }

    nonisolated func canonical(_ id: String?) -> String? { id.map { canonical($0) } }

    /// 2つの識別子が同じネットワーク（まとめたものを含む）を指すか
    nonisolated func same(_ a: String?, _ b: String?) -> Bool { canonical(a) == canonical(b) }

    /// 代表のネットワーク（一覧に出すもの）。新しく計測を始めた順
    nonisolated var representatives: [KnownNetwork] {
        values.filter { canonical($0.id) == $0.id }.sorted { $0.first > $1.first }
    }

    /// `id` にまとめたネットワーク（`id` 自身は含まない）
    nonisolated func members(of id: String) -> [KnownNetwork] {
        values.filter { $0.id != id && canonical($0.id) == id }.sorted { $0.first < $1.first }
    }

    /// `source` を `target` にまとめる。`source` にまとめてあったものも一緒に移る。
    /// まとめ先に SSID・名前が無ければ `source` のものを引き継ぐ
    nonisolated mutating func merge(_ source: String, into target: String) {
        let from = canonical(source), to = canonical(target)
        guard from != to, let s = self[from], self[to] != nil else { return }
        for (id, n) in self where id == from || n.mergedInto == from {
            self[id]?.mergedInto = to
            self[id]?.keepSeparate = nil
        }
        if self[to]?.ssid?.isEmpty ?? true, let ssid = s.ssid, !ssid.isEmpty { self[to]?.ssid = ssid }
        if self[to]?.name?.isEmpty ?? true, let name = s.name, !name.isEmpty { self[to]?.name = name }
        let first = Swift.min(self[to]!.first, s.first)
        self[to]?.first = first
    }

    /// まとめたものを分け直す。以後、自動ではまとめない
    nonisolated mutating func separate(_ id: String) {
        guard self[id]?.mergedInto != nil else { return }
        self[id]?.mergedInto = nil
        self[id]?.keepSeparate = true
    }

    /// 自分で名前を付ける（空なら外す）
    nonisolated mutating func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self[id]?.name = trimmed.isEmpty ? nil : trimmed
    }

    /// ゲートウェイの IP で登録したもの（`ip:…`）を、同じゲートウェイ・同じ SSID のルーターの MAC の登録にまとめる。
    /// ARP 表が読めない状態で起動すると、同じネットワークが2つに分かれて登録されるため。
    /// ゲートウェイの IP はどこでも同じ（192.168.1.1 など）なので、SSID が一致して候補が1つのときだけまとめる。
    /// まとめたら true
    @discardableResult
    nonisolated mutating func autoMerge() -> Bool {
        var changed = false
        for n in values where n.isGatewayOnly && n.mergedInto == nil && n.keepSeparate != true {
            guard let ssid = n.ssid, !ssid.isEmpty else { continue }
            let candidates = values.filter {
                !$0.isGatewayOnly && $0.mergedInto == nil && $0.gateway == n.gateway && $0.ssid == ssid
            }
            guard candidates.count == 1 else { continue }
            merge(n.id, into: candidates[0].id)
            changed = true
        }
        return changed
    }
}

/// レポートなどで、どのネットワークの記録を見るか
nonisolated enum NetworkFilter: Hashable, Sendable {
    case all
    case network(String)

    /// `networks` を渡すと、まとめたネットワークの記録も含める
    func includes(_ net: String?, in networks: [String: KnownNetwork] = [:]) -> Bool {
        switch self {
        case .all: true
        case .network(let id): net != nil && networks.same(net, id)
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
        return decode(lines: text, as: T.self)
    }

    /// JSON Lines を1行ずつ読む。読めない行（書き込み途中で切れた行など）は飛ばす
    static func decode<T: Decodable>(lines text: String, as: T.Type) -> [T] {
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    /// JSON Lines の1行（改行つき）
    static func line<T: Encodable>(_ row: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(row) else { return nil }
        data.append(0x0A)
        return data
    }

    static func append<T: Encodable>(_ row: T, to name: String) {
        guard let data = line(row) else { return }
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
