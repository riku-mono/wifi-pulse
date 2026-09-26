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

    var displayName: String { name ?? mdns ?? vendor_ja ?? vendor ?? (random == true ? String(localized: "Device with a Private Address") : String(localized: "Unknown Device")) }
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

/// ARP テーブル・OUI（オフライン）・mDNS 逆引きで LAN の機器一覧を作る。
@Observable
final class DeviceScanner {
    private(set) var devices: [Device] = []
    private(set) var isSweeping = false
    private(set) var lastUpdate: Date?
    private(set) var arpWorks = true
    private(set) var onlineCount = 0

    @ObservationIgnored private var registry: [String: Device] = [:]
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private weak var monitor: Monitor?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sweepRequested = true
    @ObservationIgnored private var lastNameLookup = Date.distantPast

    static let cycle: Duration = .seconds(20)

    func start(monitor: Monitor) {
        guard loop == nil else { return }
        self.monitor = monitor
        registry = DataStore.readJSON(DataStore.devices, as: [String: Device].self) ?? [:]
        names = DataStore.readJSON(DataStore.deviceNames, as: [String: String].self) ?? [:]
        loop = Task { await run() }
    }

    func requestSweep() {
        sweepRequested = true
        loop?.cancel()
        loop = Task { await run() }
    }

    func rename(_ mac: String, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if trimmed.isEmpty { names.removeValue(forKey: mac) } else { names[mac] = trimmed }
        registry[mac]?.name = names[mac]
        let snapshot = names
        Task.detached(priority: .utility) { DataStore.writeJSON(snapshot, to: DataStore.deviceNames) }
        publish()
    }

    private func run() async {
        while !Task.isCancelled {
            guard let monitor else { return }
            let env = monitor.env
            if sweepRequested, !env.gateway.isEmpty {
                sweepRequested = false
                isSweeping = true
                await Self.sweep(interface: env.interface)
                isSweeping = false
            }
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
            // mDNS名の逆引きは重いので2分に1回
            if Date().timeIntervalSince(lastNameLookup) > 120 {
                lastNameLookup = Date()
                for mac in online where registry[mac]?.mdns == nil {
                    if let ip = registry[mac]?.ip {
                        registry[mac]?.mdns = await Self.mdnsName(ip, gateway: env.gateway)
                    }
                }
            }
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
            let snapshot = registry
            Task.detached(priority: .utility) { DataStore.writeJSON(snapshot, to: DataStore.devices) }
            try? await Task.sleep(for: Self.cycle)
        }
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

    /// ARP を埋めるため、同じサブネット（広くても /24）の全アドレスへ UDP を1発ずつ投げる（中身は空、宛先は discard ポート）。
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
        var table: [String: String] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= size {
                let msgLen = Int(raw.load(fromByteOffset: offset, as: UInt16.self))
                guard msgLen > 0 else { break }
                defer { offset += msgLen }
                let sinOffset = offset + MemoryLayout<rt_msghdr>.size
                let sinLen = Int(raw[sinOffset])
                guard raw[sinOffset + 1] == UInt8(AF_INET) else { continue }
                let addr = raw.loadUnaligned(fromByteOffset: sinOffset + 4, as: UInt32.self)
                let dlOffset = sinOffset + (sinLen > 0 ? (1 + ((sinLen - 1) | 3)) : 4)
                guard dlOffset + 8 <= offset + msgLen, raw[dlOffset + 1] == UInt8(AF_LINK) else { continue }
                let nlen = Int(raw[dlOffset + 5]), alen = Int(raw[dlOffset + 6])
                guard alen == 6 else { continue }
                let mac = (0..<6).map { String(format: "%02x", raw[dlOffset + 8 + nlen + $0]) }.joined(separator: ":")
                var a = in_addr(s_addr: addr)
                var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &a, &out, socklen_t(out.count))
                table[String(cString: out)] = mac
            }
        }
        return table
    }

    /// サブネット内のホスト（ネットワーク・ブロードキャストのアドレスと自分を除く）。/24 より広ければ自分の /24 に絞る。
    nonisolated static func sweepTargets(ip: UInt32, netmask: UInt32) -> [UInt32] {
        let mask = netmask | 0xFFFF_FF00
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
            for line in out.split(separator: "\n") {
                var name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.hasPrefix(";") else { continue }
                if name.hasSuffix(".") { name.removeLast() }
                if name.hasSuffix(".local") { name.removeLast(6) }
                return name
            }
        }
        return nil
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

    private static func classify(_ d: Device, env: NetworkEnvironment) -> (String?, String) {
        let hay = "\(d.vendor ?? "") \(d.mdns ?? "")".lowercased()
        var label = d.vendor
        var kind = "unknown"
        if let rule = vendorRules.first(where: { hay.contains($0.0) }) {
            label = rule.1
            kind = rule.2
        }
        let mdns = (d.mdns ?? "").lowercased()
        if let hint = nameHints.first(where: { mdns.contains($0.0) }) { kind = hint.1 }
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
