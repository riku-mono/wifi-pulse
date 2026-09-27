import Foundation
import Observation

/// LAN 上の機器。devices.json に Python 版と同じく MAC をキーにした辞書で保存する。
nonisolated struct Device: Codable, Identifiable, Hashable, Sendable {
    var id: String { mac }
    var mac: String
    var ip: String?
    var first: Int64
    var last: Int64
    var vendor: String?
    var random: Bool?
    var mdns: String?
    var kind: String?
    var vendor_ja: String?
    var online: Bool?
    var name: String?
    /// 最後に見えたネットワークの識別子（`NetworkEnvironment.networkID`）
    var net: String?
    /// Bonjour のサービス名（「リビングルーム」「Brother DCP-J928N」など）
    var service: String?
    /// Bonjour の TXT レコードの機種（`AppleTV14,1` など）
    var model: String?
    /// Bonjour で見つかったサービスの種類（`airplay`・`ipp` など）
    var services: [String]?

    /// Bonjour だけで見つかり、MAC アドレスが分からない機器は `ip:<IP アドレス>` をキーにする
    static let ipKeyPrefix = "ip:"
    var hasMAC: Bool { !mac.hasPrefix(Self.ipKeyPrefix) }

    var displayName: String { name ?? service ?? mdns ?? vendor_ja ?? vendor ?? (random == true ? String(localized: "Device with a Private Address") : String(localized: "Unknown Device")) }
    var lastSeen: Date { Date(epochMs: last) }
    var firstSeen: Date { Date(epochMs: first) }

    var symbol: String {
        switch kind {
        case "router": "wifi.router"
        case "pc": "laptopcomputer"
        case "phone": "iphone"
        case "tablet": "ipad"
        case "game": "gamecontroller"
        case "media": "tv"
        case "speaker": "homepod"
        case "printer": "printer"
        case "appliance": "washer"
        case "iot": "sensor"
        default: "questionmark.square.dashed"
        }
    }

    var kindLabel: String {
        switch kind {
        case "router": String(localized: "Router", comment: "機器の種類")
        case "pc": String(localized: "Computer")
        case "phone": String(localized: "Smartphone")
        case "tablet": String(localized: "Tablet")
        case "game": String(localized: "Game Console")
        case "media": String(localized: "TV / Video")
        case "speaker": String(localized: "Speaker")
        case "printer": String(localized: "Printer")
        case "appliance": String(localized: "Appliance")
        case "iot": String(localized: "IoT Device")
        default: String(localized: "Unknown")
        }
    }
}

/// ARP テーブル・Bonjour・OUI（オフライン）・mDNS 逆引きで LAN の機器一覧を作る。
/// ARP 表は署名によって空に見えることがある（#5）ので、Bonjour でサービスを公開している機器も加える。
@Observable
final class DeviceScanner {
    private(set) var devices: [Device] = []
    private(set) var isSweeping = false
    private(set) var lastUpdate: Date?
    private(set) var arpWorks = true
    private(set) var onlineCount = 0
    /// Bonjour で探すことを拒否された（ローカルネットワークの許可が無い）
    private(set) var bonjourDenied = false
    /// LAN の機器の画面を開いているか。開いている間だけ Bonjour で定期的に探す
    @ObservationIgnored var isViewing = false {
        // 探している最中なら止めずに、その結果を使う（止めると途中までしか見つからない）
        didSet { if isViewing, !oldValue, !isBusy, Date().timeIntervalSince(lastBrowse) > Self.browseInterval { wake() } }
    }

    @ObservationIgnored private var registry: [String: Device] = [:]
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private weak var monitor: Monitor?
    @ObservationIgnored private let loop = SerialTask()
    @ObservationIgnored private var sweepRequested = true
    @ObservationIgnored private var lastNameLookup = Date.distantPast
    @ObservationIgnored private var lastBrowse = Date.distantPast
    /// 掃引・Bonjour・ARP の読み取りの最中（周期の待ちの間は false）
    @ObservationIgnored private var isBusy = false
    /// Bonjour で最後に見えた日時（registry のキーごと）。ARP に出ない機器のオンライン判定に使う
    @ObservationIgnored private var bonjourSeen: [String: Date] = [:]
    /// いま掃引してはいけないか（速度測定・負荷試験の最中。結果が下がる）。頼まれた掃引は次の周期へ回す。`AppModel` が設定する
    @ObservationIgnored var isBlocked: () -> Bool = { false }

    static let cycle: Duration = .seconds(20)
    /// 画面を開いている間に Bonjour で探す間隔（掃引のときは間隔によらず探す）
    static let browseInterval: TimeInterval = 120
    /// Bonjour で最後に見えてから、この秒数まではオンラインとみなす
    static let bonjourOnlineWindow: TimeInterval = 300

    func start(monitor: Monitor) {
        guard !loop.hasStarted else { return }
        self.monitor = monitor
        registry = Self.repaired(DataStore.readJSON(DataStore.devices, as: [String: Device].self) ?? [:])
        names = DataStore.readJSON(DataStore.deviceNames, as: [String: String].self) ?? [:]
        loop.restart { [weak self] in await self?.run() }
    }

    /// 進行中の掃引が終わるまで待つ
    func waitUntilIdle() async {
        while isSweeping { try? await Task.sleep(for: .milliseconds(200)) }
    }

    func requestSweep() {
        sweepRequested = true
        wake()
    }

    /// 待たずに次の周期を始める
    private func wake() {
        guard monitor != nil else { return }
        // 前のループが止まってから始める（2つのループが await をはさんで registry を同時に書き換えないように）
        loop.restart { [weak self] in await self?.run() }
    }

    func rename(_ mac: String, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if trimmed.isEmpty { names.removeValue(forKey: mac) } else { names[mac] = trimmed }
        registry[mac]?.name = names[mac]
        saveNames()
        publish()
    }

    private func saveNames() {
        let snapshot = names
        Task.detached(priority: .utility) { DataStore.writeJSON(snapshot, to: DataStore.deviceNames) }
    }

    /// 読み込んだ登録を直す。#16 で直す前に保存した mDNS 名（`Doorbell\032Repeater` など）のエスケープを戻す。
    /// 名前がある機器には問い合わせ直さないので、読み込むときに直す
    /// あわせて、ループバックに解決された登録（`ip:127.0.0.1`。この Mac 自身）を除く
    nonisolated static func repaired(_ registry: [String: Device]) -> [String: Device] {
        registry.filter { !($0.key.hasPrefix(Device.ipKeyPrefix) && $0.value.ip?.hasPrefix("127.") == true) }.mapValues { d in
            var d = d
            if let name = d.mdns, name.contains("\\") { d.mdns = unescapeDNS(name) }
            return d
        }
    }

    /// Bonjour で見つかった機器を registry に入れる。ARP 表に同じ IP があればその MAC の登録に、
    /// 無ければ `ip:<IP>` の登録に入れる。入れた登録のキーを返す
    nonisolated static func mergeBonjour(_ found: [String: BonjourDevice], arp: [String: String],
                                         into registry: inout [String: Device], net: String?, now: Int64) -> [String] {
        var keys: [String] = []
        for (ip, b) in found {
            let key = arp[ip] ?? Device.ipKeyPrefix + ip
            var d = registry[key] ?? Device(mac: key, first: now, last: now)
            d.ip = ip
            d.last = now
            d.net = net
            if let name = b.name { d.service = name }
            if let model = b.model { d.model = model }
            d.services = Array(Set(d.services ?? []).union(b.services)).sorted()
            registry[key] = d
            keys.append(key)
        }
        return keys
    }

    /// `ip:<IP>` の登録のうち、ARP 表でその IP の MAC が分かったものを MAC の登録に移す（付けた名前も移す）。
    /// 移した `ip:…` のキーを返す
    nonisolated static func adoptIPEntries(arp: [String: String], registry: inout [String: Device],
                                           names: inout [String: String]) -> [String] {
        var moved: [String] = []
        for (key, old) in registry where !old.hasMAC {
            guard let ip = old.ip, let mac = arp[ip], var d = registry[mac] else { continue }
            if d.service == nil { d.service = old.service }
            if d.model == nil { d.model = old.model }
            let services = Set(d.services ?? []).union(old.services ?? [])
            d.services = services.isEmpty ? nil : services.sorted()
            d.first = min(d.first, old.first)
            if let name = names.removeValue(forKey: key), names[mac] == nil {
                names[mac] = name
                d.name = name
            }
            registry[mac] = d
            registry.removeValue(forKey: key)
            moved.append(key)
        }
        return moved
    }

    private func run() async {
        while !Task.isCancelled {
            guard let monitor else { return }
            let env = monitor.env
            let sweeping = sweepRequested && !env.gateway.isEmpty && !isBlocked()
            let browsing = !env.gateway.isEmpty && (sweeping || (isViewing && Date().timeIntervalSince(lastBrowse) > Self.browseInterval))
            // Bonjour は掃引と並べて探す（掃引の3秒の待ちと重なる）
            isBusy = true
            async let bonjour: Bonjour.Result? = browsing ? Bonjour.discover() : nil
            if sweeping {
                sweepRequested = false
                isSweeping = true
                await Self.sweep(interface: env.interface)
            }
            let found = await bonjour
            let arp = await Self.arpTable()
            if arpWorks != !arp.isEmpty { arpWorks = !arp.isEmpty }
            let now = Date().epochMs
            var online = Set<String>()
            for (ip, mac) in arp {
                var d = registry[mac] ?? Device(mac: mac, first: now, last: now)
                d.ip = ip
                d.last = now
                d.net = env.networkID
                if d.vendor == nil {
                    d.vendor = await OUI.shared.vendor(for: mac)
                    d.random = OUI.isRandomized(mac)
                }
                registry[mac] = d
                online.insert(mac)
            }
            // Bonjour だけで見つけていた機器の MAC が分かったら、MAC の登録に移す
            let adopted = Self.adoptIPEntries(arp: arp, registry: &registry, names: &names)
            if !adopted.isEmpty {
                adopted.forEach { bonjourSeen.removeValue(forKey: $0) }
                saveNames()
            }
            if let found {
                // 途中で止められた探索は、見つかった分だけ使って次の周期でもう一度探す
                if !Task.isCancelled { lastBrowse = Date() }
                if bonjourDenied != found.denied { bonjourDenied = found.denied }
                for key in Self.mergeBonjour(found.devices, arp: arp, into: &registry, net: env.networkID, now: now) {
                    bonjourSeen[key] = Date()
                }
            }
            bonjourSeen = bonjourSeen.filter { Date().timeIntervalSince($0.value) < Self.bonjourOnlineWindow && registry[$0.key] != nil }
            online.formUnion(bonjourSeen.keys)
            // 見つかった機器はすぐ出す（mDNS名の逆引きを待つと、掃引のあと数秒「見つかりません」になる）
            update(online: online, env: env)
            isSweeping = false
            // mDNS名の逆引きは重いので2分に1回
            if Date().timeIntervalSince(lastNameLookup) > 120 {
                lastNameLookup = Date()
                // Bonjour の名前がある機器は問い合わせない（dig を起動する数を減らす）
                for mac in online where registry[mac]?.mdns == nil && registry[mac]?.service == nil {
                    if let ip = registry[mac]?.ip {
                        // 待っている間に registry へ書き込みが続かないよう、結果を受け取ってから入れる
                        let name = await Self.mdnsName(ip, gateway: env.gateway)
                        registry[mac]?.mdns = name
                    }
                }
                update(online: online, env: env)
            }
            let snapshot = registry
            Task.detached(priority: .utility) { DataStore.writeJSON(snapshot, to: DataStore.devices) }
            isBusy = false
            try? await Task.sleep(for: Self.cycle)
        }
    }

    private func update(online: Set<String>, env: NetworkEnvironment) {
        for mac in registry.keys {
            registry[mac]?.online = online.contains(mac)
            registry[mac]?.name = names[mac]
            if let d = registry[mac] {
                let (label, kind) = Self.classify(d, env: env)
                registry[mac]?.vendor_ja = label
                registry[mac]?.kind = kind
            }
        }
        publish()
    }

    /// 変化があったときだけ書き換える（一覧の無駄な再描画を避ける）
    private func publish() {
        let sorted = registry.values.sorted {
            if ($0.online ?? false) != ($1.online ?? false) { return $0.online ?? false }
            return Self.ipSortKey($0.ip) < Self.ipSortKey($1.ip)
        }
        if sorted != devices { devices = sorted }
        let online = sorted.filter { $0.online == true }.count
        if online != onlineCount { onlineCount = online }
    }

    private static func ipSortKey(_ ip: String?) -> Int {
        guard let ip else { return .max }
        return ip.split(separator: ".").compactMap { Int($0) }.reduce(0) { $0 * 256 + $1 }
    }

    // MARK: Sources

    /// ARP を埋めるため、同じサブネット（広くても /22）の全アドレスへ UDP を1発ずつ投げる（中身は空、宛先は discard ポート）。
    nonisolated static func sweep(interface: String) async {
        let targets = sweepTargets(interface: interface)
        guard !targets.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                if fd >= 0 {
                    defer { close(fd) }
                    for target in targets {
                        var addr = sockaddr_in()
                        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                        addr.sin_family = sa_family_t(AF_INET)
                        addr.sin_port = in_port_t(9).bigEndian
                        addr.sin_addr.s_addr = target.bigEndian
                        _ = withUnsafePointer(to: &addr) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, nil, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
                cont.resume()
            }
        }
        try? await Task.sleep(for: .seconds(3))
    }

    /// 掃引する宛先（ホストバイト順）。ARP を使わないリンクや1対1のリンク（iPhone のテザリングで
    /// 192.0.0.2/32 になるときなど）には LAN が無く、サブネットの外へ投げると sendto がカーネル内で
    /// 回り続けて CPU を 100% 使うので、何も投げない。
    nonisolated static func sweepTargets(interface: String) -> [UInt32] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == interface,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            if flags & (IFF_NOARP | IFF_POINTOPOINT) != 0 { return [] }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return sweepTargets(ip: ip, netmask: netmask)
        }
        return []
    }

    /// ARP 表を sysctl（NET_RT_FLAGS / RTF_LLINFO）で直接読む。`arp -an` と同じ情報だが、
    /// アプリから起動した `arp` コマンドには空の表しか返ってこないことがある（macOS 27 で確認）ので、自分で読む。
    nonisolated static func readARP() -> [String: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, 0x400 /* RTF_LLINFO */]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) == 0 else { return [:] }
        return parseARP(Array(buf.prefix(size)))
    }

    /// sysctl が返す経路メッセージ（`rt_msghdr` ＋ `sockaddr_inarp` ＋ `sockaddr_dl`）の並びから IP → MAC を取り出す。
    /// IPv4 でないもの・リンク層のアドレスが無いもの・MAC が6バイトでないもの（未解決の項目など）は飛ばす
    nonisolated static func parseARP(_ buf: [UInt8]) -> [String: String] {
        let size = buf.count
        var table: [String: String] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= size {
                let msgLen = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard msgLen > 0 else { break }
                defer { offset += msgLen }
                let sinOffset = offset + MemoryLayout<rt_msghdr>.size
                guard offset + msgLen <= size, sinOffset + 8 <= offset + msgLen else { continue }
                let sinLen = Int(raw[sinOffset])
                guard raw[sinOffset + 1] == UInt8(AF_INET) else { continue }
                let addr = raw.loadUnaligned(fromByteOffset: sinOffset + 4, as: UInt32.self)
                let dlOffset = sinOffset + (sinLen > 0 ? (1 + ((sinLen - 1) | 3)) : 4)
                guard dlOffset + 8 <= offset + msgLen, raw[dlOffset + 1] == UInt8(AF_LINK) else { continue }
                let nlen = Int(raw[dlOffset + 5]), alen = Int(raw[dlOffset + 6])
                guard alen == 6, dlOffset + 8 + nlen + 6 <= offset + msgLen else { continue }
                let mac = (0..<6).map { String(format: "%02x", raw[dlOffset + 8 + nlen + $0]) }.joined(separator: ":")
                let host = UInt32(bigEndian: addr)
                let ip = [24, 16, 8, 0].map { String(host >> UInt32($0) & 0xFF) }.joined(separator: ".")
                table[ip] = mac
            }
        }
        return table
    }

    /// サブネット内のホスト（ネットワーク・ブロードキャストのアドレスと自分を除く）。/22 より広ければ自分の /22 に絞る
    /// （家庭用のメッシュ Wi-Fi には /22 のものがある。それより広いと1回の掃引が重くなる）。
    nonisolated static func sweepTargets(ip: UInt32, netmask: UInt32) -> [UInt32] {
        let mask = netmask | 0xFFFF_FC00
        guard mask <= 0xFFFF_FFFC else { return [] }  // /31・/32 には相手がいない
        let network = ip & mask
        let broadcast = network | ~mask
        return (network + 1 ..< broadcast).filter { $0 != ip }
    }

    /// IP → MAC。解決できていない（incomplete）ものとマルチキャスト・ブロードキャストは除く。
    nonisolated static func arpTable() async -> [String: String] {
        readARP().filter { ip, _ in !(ip.hasPrefix("224.") || ip.hasPrefix("239.") || ip.hasSuffix(".255")) }
    }

    nonisolated static func normalize(_ mac: String) -> String {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return mac.lowercased() }
        return parts.map { String(format: "%02x", Int($0, radix: 16) ?? 0) }.joined(separator: ":")
    }

    nonisolated static func mdnsName(_ ip: String, gateway: String) async -> String? {
        for server in [["@224.0.0.251", "-p", "5353"], ["@\(gateway)"]] {
            let out = await Shell.run("/usr/bin/dig", ["+short", "-x", ip] + server + ["+time=2", "+tries=1"], timeout: 6)
            if let name = hostName(fromDig: out) { return name }
        }
        return nil
    }

    /// `dig +short -x` の出力から名前を取り出す（最初の名前だけ。末尾の `.` と `.local` を外す）
    nonisolated static func hostName(fromDig out: String) -> String? {
        for line in out.split(separator: "\n") {
            var name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix(";") else { continue }
            if name.hasSuffix("."), !name.hasSuffix("\\.") { name.removeLast() }
            if name.hasSuffix(".local") { name.removeLast(6) }
            return unescapeDNS(name)
        }
        return nil
    }

    /// DNS の表記のエスケープを戻す。`\DDD` は10進のバイト（空白は `\032`、日本語は UTF-8 の1バイトずつ）、`\X` は X そのもの
    nonisolated static func unescapeDNS(_ s: String) -> String {
        var bytes: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let c = it.popFirst() {
            guard c == UInt8(ascii: "\\"), let next = it.first else { bytes.append(c); continue }
            let digits = it.prefix(3)
            if digits.count == 3, digits.allSatisfy({ (0x30...0x39).contains($0) }),
               let v = UInt8(String(decoding: digits, as: UTF8.self)) {
                bytes.append(v)
                it.removeFirst(3)
            } else {
                bytes.append(next)
                it.removeFirst()
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Classification

    private static let vendorRules: [(String, String, String)] = [
        ("apple", "Apple", "apple"), ("nintendo", String(localized: "Nintendo"), "game"),
        ("sony interactive", String(localized: "Sony (PlayStation)"), "game"), ("sony", String(localized: "Sony"), "media"),
        ("microsoft", "Microsoft", "pc"), ("amazon", "Amazon", "media"),
        ("google", "Google", "media"), ("sercomm", String(localized: "Sercomm (ISP-provided)"), "router"),
        ("sernet", String(localized: "Sercomm (ISP-provided)"), "router"), ("arcadyan", "Arcadyan", "router"),
        ("buffalo", String(localized: "Buffalo"), "router"), ("nec platforms", "NEC", "router"),
        ("tp-link", "TP-Link", "router"), ("aterm", "NEC Aterm", "router"),
        ("seiko epson", String(localized: "Epson"), "printer"), ("canon", String(localized: "Canon"), "printer"),
        ("brother", String(localized: "Brother"), "printer"), ("sharp", String(localized: "Sharp"), "appliance"),
        ("panasonic", String(localized: "Panasonic"), "appliance"), ("hitachi", String(localized: "Hitachi"), "appliance"),
        ("daikin", String(localized: "Daikin"), "appliance"), ("roborock", String(localized: "Roborock"), "appliance"),
        ("samsung", "Samsung", "phone"), ("xiaomi", "Xiaomi", "phone"),
        ("huawei", "Huawei", "phone"), ("oppo", "OPPO", "phone"),
        ("espressif", String(localized: "Espressif (IoT device)"), "iot"), ("tuya", String(localized: "Tuya (smart home)"), "iot"),
        ("raspberry", "Raspberry Pi", "pc"), ("intel", String(localized: "Intel (built into PC)"), "pc"),
        ("sonos", "Sonos", "speaker"), ("bose", "Bose", "speaker"), ("anker", "Anker", "media"),
    ]
    private static let nameHints: [(String, String)] = [
        ("iphone", "phone"), ("android", "phone"), ("pixel", "phone"), ("galaxy", "phone"),
        ("ipad", "tablet"), ("macbook", "pc"), ("imac", "pc"), ("mac-", "pc"), ("mac-mini", "pc"),
        ("apple-tv", "media"), ("appletv", "media"), ("switch", "game"), ("playstation", "game"),
        ("ps5", "game"), ("echo", "speaker"), ("homepod", "speaker"), ("alexa", "speaker"),
        ("chromecast", "media"), ("nest", "media"), ("printer", "printer"), ("epson", "printer"),
        ("tv", "media"), ("bravia", "media"), ("aquos", "media"), ("regza", "media"),
        ("viera", "media"), ("roku", "media"), ("firetv", "media"),
    ]

    /// Bonjour のサービスの種類から分かる機器の種類（名前・機種から分かればそちらを優先）
    private static let serviceHints: [(String, String)] = [
        ("ipp", "printer"), ("ipps", "printer"), ("pdl-datastream", "printer"),
        ("googlecast", "media"), ("hap", "iot"), ("airplay", "media"), ("spotify-connect", "speaker"), ("raop", "speaker"),
    ]
    /// TXT レコードの機種の先頭（`AppleTV14,1` → media など）
    private static let modelHints: [(String, String)] = [
        ("appletv", "media"), ("audioaccessory", "speaker"), ("iphone", "phone"), ("ipad", "tablet"),
        ("macbook", "pc"), ("macmini", "pc"), ("imac", "pc"), ("macpro", "pc"), ("mac", "pc"), ("chromecast", "media"),
    ]

    static func classify(_ d: Device, env: NetworkEnvironment) -> (String?, String) {
        let hay = "\(d.vendor ?? "") \(d.mdns ?? "")".lowercased()
        var label = d.vendor
        var kind = "unknown"
        if let rule = vendorRules.first(where: { hay.contains($0.0) }) {
            label = rule.1
            kind = rule.2
        }
        let services = Set(d.services ?? [])
        if let hint = serviceHints.first(where: { services.contains($0.0) }) { kind = hint.1 }
        let names = "\(d.mdns ?? "") \(d.service ?? "")".lowercased()
        if let hint = nameHints.first(where: { names.contains($0.0) }) { kind = hint.1 }
        let model = (d.model ?? "").lowercased()
        if let hint = modelHints.first(where: { model.hasPrefix($0.0) }) { kind = hint.1 }
        if kind == "apple" { kind = "unknown" }
        if d.ip == env.gateway { kind = "router" } else if d.ip == env.selfIP { kind = "pc" }
        return (label, kind)
    }
}

/// MAC アドレス先頭3バイト → メーカー名（IEEE公開データをアプリに同梱。ネット通信なし）。
actor OUI {
    static let shared = OUI()
    private var table: [String: String]?

    func vendor(for mac: String) -> String? {
        if table == nil { table = Self.load() }
        let key = mac.replacingOccurrences(of: ":", with: "").uppercased().prefix(6)
        return table?[String(key)]
    }

    private static func load() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var t: [String: String] = [:]
        t.reserveCapacity(40000)
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            t[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return t
    }

    /// ローカル管理アドレス（iPhone/Mac のプライベート Wi-Fi アドレスなど）か
    nonisolated static func isRandomized(_ mac: String) -> Bool {
        guard let first = mac.split(separator: ":").first, let b = UInt8(first, radix: 16) else { return false }
        return b & 0x02 != 0
    }
}
