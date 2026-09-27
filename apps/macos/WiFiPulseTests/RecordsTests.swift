import Foundation
import Testing
@testable import WiFiPulse

struct TestHostTests {
    /// テストの実行時はアプリが計測を始めない（`AppEntry` がこの環境変数で見分ける）
    @Test func runsInsideTheTestHost() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }
}

struct DataStoreTests {
    static let row = ReportTests.minute(hour: 3)

    @Test func roundTripsJSONLines() throws {
        var rows = [Self.row, Self.row]
        rows[1].net = "aa:bb:cc:dd:ee:ff"
        let data = rows.compactMap { DataStore.line($0) }.reduce(Data(), +)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(text.split(separator: "\n").count == 2)

        let decoded = DataStore.decode(lines: text, as: MinuteRow.self)
        try #require(decoded.count == 2)
        #expect(decoded[0].net == nil)
        #expect(decoded[1].net == "aa:bb:cc:dd:ee:ff")
        #expect(decoded[1].gw50 == Self.row.gw50)
    }

    /// 書き込み途中で切れた行や壊れた行は飛ばし、残りは読む
    @Test func skipsBrokenLines() throws {
        let good = String(decoding: try #require(DataStore.line(Self.row)), as: UTF8.self)
        let text = good + "not json\n" + "\n" + good + String(good.prefix(20))
        #expect(DataStore.decode(lines: text, as: MinuteRow.self).count == 2)
    }

    /// `net` が入る前の記録も読める
    @Test func readsRecordsWithoutNetwork() {
        let old = #"{"hour":3,"n":60,"rx":0,"t":1700000000000,"tx":0,"wd":1,"v450":12.5}"#
        let rows = DataStore.decode(lines: old, as: MinuteRow.self)
        #expect(rows.count == 1)
        #expect(rows.first?.net == nil)
        #expect(rows.first?.v450 == 12.5)
    }
}

struct NetworkTests {
    @Test func filter() {
        #expect(NetworkFilter.all.includes(nil))
        #expect(NetworkFilter.all.includes("x"))
        #expect(NetworkFilter.network("x").includes("x"))
        #expect(!NetworkFilter.network("x").includes("y"))
        #expect(!NetworkFilter.network("x").includes(nil))
    }

    static let mac = "40:ed:00:00:00:01"

    /// ARP が読めずに `ip:…` で登録され、あとでルーターの MAC で別に登録された状態
    static func split(ipSSID: String? = "Home", macSSID: String? = "Home") -> [String: KnownNetwork] {
        [
            "ip:192.168.68.1": KnownNetwork(id: "ip:192.168.68.1", ssid: ipSSID, gateway: "192.168.68.1", first: 100),
            mac: KnownNetwork(id: mac, ssid: macSSID, gateway: "192.168.68.1", first: 200),
        ]
    }

    @Test func filterIncludesMergedNetworks() {
        var nets = Self.split()
        #expect(!NetworkFilter.network(Self.mac).includes("ip:192.168.68.1", in: nets))
        nets.merge("ip:192.168.68.1", into: Self.mac)
        #expect(NetworkFilter.network(Self.mac).includes("ip:192.168.68.1", in: nets))
        #expect(NetworkFilter.network(Self.mac).includes(Self.mac, in: nets))
        // まとめた側を選んでいても代表の分として見る
        #expect(NetworkFilter.network("ip:192.168.68.1").includes(Self.mac, in: nets))
        #expect(!NetworkFilter.network(Self.mac).includes(nil, in: nets))
        #expect(!NetworkFilter.network(Self.mac).includes("other", in: nets))
    }

    @Test func mergeCarriesSSIDAndFirstDate() {
        var nets = Self.split(macSSID: nil)
        nets.merge("ip:192.168.68.1", into: Self.mac)
        #expect(nets.canonical("ip:192.168.68.1") == Self.mac)
        #expect(nets[Self.mac]?.ssid == "Home")
        #expect(nets[Self.mac]?.first == 100)
        #expect(nets.representatives.map(\.id) == [Self.mac])
        #expect(nets.members(of: Self.mac).map(\.id) == ["ip:192.168.68.1"])
        // 記録側の識別子は変わらないので、分け直せる
        nets.separate("ip:192.168.68.1")
        #expect(nets.canonical("ip:192.168.68.1") == "ip:192.168.68.1")
        #expect(nets.representatives.count == 2)
    }

    /// まとめ先をさらにまとめても、代表は1段でたどれる
    @Test func mergeMovesMembersAlong() {
        var nets = Self.split()
        nets["c"] = KnownNetwork(id: "c", gateway: "10.0.0.1", first: 50)
        nets.merge("ip:192.168.68.1", into: Self.mac)
        nets.merge(Self.mac, into: "c")
        #expect(nets["ip:192.168.68.1"]?.mergedInto == "c")
        #expect(nets[Self.mac]?.mergedInto == "c")
        #expect(nets.representatives.map(\.id) == ["c"])
        // 自分の仲間にはまとめられない
        nets.merge("c", into: Self.mac)
        #expect(nets["c"]?.mergedInto == nil)
    }

    @Test func canonicalStopsOnACycle() {
        var nets = Self.split()
        nets["ip:192.168.68.1"]?.mergedInto = Self.mac
        nets[Self.mac]?.mergedInto = "ip:192.168.68.1"
        _ = nets.canonical(Self.mac)
        #expect(nets.canonical("unknown") == "unknown")
    }

    @Test func autoMergeNeedsTheSameSSID() {
        var same = Self.split()
        let sameMerged = same.autoMerge()
        #expect(sameMerged)
        #expect(same.canonical("ip:192.168.68.1") == Self.mac)

        var noSSID = Self.split(macSSID: nil)
        let noSSIDMerged = noSSID.autoMerge()
        #expect(!noSSIDMerged)
        var other = Self.split(macSSID: "Cafe")
        let otherMerged = other.autoMerge()
        #expect(!otherMerged)

        // 同じゲートウェイ・同じ SSID のルーターが2つあると、どちらか決められない
        var two = Self.split()
        two["aa"] = KnownNetwork(id: "aa", ssid: "Home", gateway: "192.168.68.1", first: 300)
        let twoMerged = two.autoMerge()
        #expect(!twoMerged)
    }

    @Test func autoMergeRespectsSeparation() {
        var nets = Self.split()
        nets.autoMerge()
        nets.separate("ip:192.168.68.1")
        let netsMerged = nets.autoMerge()
        #expect(!netsMerged)
        #expect(nets.representatives.count == 2)
    }

    @Test func nameOverridesSSID() {
        var nets = Self.split()
        nets.rename(Self.mac, to: "  Living Room  ")
        #expect(nets[Self.mac]?.name == "Living Room")
        #expect(nets[Self.mac]?.displayName == "Living Room")
        nets.rename(Self.mac, to: " ")
        #expect(nets[Self.mac]?.name == nil)
        #expect(nets[Self.mac]?.displayName == "Home")
    }

    /// 項目が増える前の networks.json も読める
    @Test func decodesOldRegistry() throws {
        let json = #"{"ip:192.168.1.1":{"first":1,"gateway":"192.168.1.1","id":"ip:192.168.1.1"}}"#
        let nets = try JSONDecoder().decode([String: KnownNetwork].self, from: Data(json.utf8))
        #expect(nets["ip:192.168.1.1"]?.mergedInto == nil)
        #expect(nets["ip:192.168.1.1"]?.isGatewayOnly == true)
    }

    @Test func networkIDPrefersTheRouterMAC() {
        var env = NetworkEnvironment()
        #expect(env.networkID == nil)
        env.gateway = "192.168.1.1"
        #expect(env.networkID == "ip:192.168.1.1")
        env.routerMAC = "aa:bb:cc:dd:ee:ff"
        #expect(env.networkID == "aa:bb:cc:dd:ee:ff")
    }
}

struct DeviceScannerTests {
    static func ip(_ s: String) -> UInt32 {
        s.split(separator: ".").reduce(0) { $0 << 8 | UInt32($1)! }
    }

    /// sysctl(NET_RT_FLAGS) が返す1件ぶん（`rt_msghdr` ＋ `sockaddr_inarp` ＋ `sockaddr_dl`）
    static func arpMessage(ip: [UInt8], mac: [UInt8]?, name: String = "en0", family: Int32 = AF_INET) -> [UInt8] {
        var sin = [UInt8](repeating: 0, count: 16)
        sin[0] = 16
        sin[1] = UInt8(family)
        sin.replaceSubrange(4..<8, with: ip)
        let nameBytes = Array(name.utf8)
        var dl: [UInt8] = [0, UInt8(AF_LINK), 4, 0, 6, UInt8(nameBytes.count), UInt8(mac?.count ?? 0), 0]
        dl += nameBytes + (mac ?? [])
        dl[0] = UInt8(dl.count)
        while dl.count % 4 != 0 { dl.append(0) }
        var header = [UInt8](repeating: 0, count: MemoryLayout<rt_msghdr>.size)
        let length = UInt16(header.count + sin.count + dl.count)
        header[0] = UInt8(length & 0xFF)
        header[1] = UInt8(length >> 8)
        return header + sin + dl
    }

    @Test func parsesTheARPTable() {
        let buf = Self.arpMessage(ip: [192, 168, 1, 1], mac: [0xaa, 0xbb, 0xcc, 0x01, 0x02, 0x03])
            + Self.arpMessage(ip: [192, 168, 1, 20], mac: nil)  // 未解決（MAC が無い）
            + Self.arpMessage(ip: [192, 168, 1, 30], mac: [1, 2, 3, 4], name: "bridge0")  // MAC が6バイトでない
            + Self.arpMessage(ip: [0, 0, 0, 0], mac: [1, 2, 3, 4, 5, 6], family: AF_INET6)
            + Self.arpMessage(ip: [10, 0, 0, 7], mac: [0x02, 0, 0, 0, 0, 0x0f], name: "en10")
        #expect(DeviceScanner.parseARP(buf) == [
            "192.168.1.1": "aa:bb:cc:01:02:03",
            "10.0.0.7": "02:00:00:00:00:0f",
        ])
    }

    /// 途中で切れたバッファや長さ0の項目で止まる（範囲の外を読まない）
    @Test func stopsOnTruncatedARPData() {
        let one = Self.arpMessage(ip: [192, 168, 1, 1], mac: [0xaa, 0xbb, 0xcc, 0x01, 0x02, 0x03])
        #expect(DeviceScanner.parseARP(Array(one.dropLast(8))).isEmpty)
        #expect(DeviceScanner.parseARP(one + [UInt8](repeating: 0, count: MemoryLayout<rt_msghdr>.size)) == ["192.168.1.1": "aa:bb:cc:01:02:03"])
        #expect(DeviceScanner.parseARP([]).isEmpty)
    }

    @Test func sweepsA24() {
        let t = DeviceScanner.sweepTargets(ip: Self.ip("192.168.1.10"), netmask: Self.ip("255.255.255.0"))
        #expect(t.count == 253)
        #expect(t.first == Self.ip("192.168.1.1"))
        #expect(t.last == Self.ip("192.168.1.254"))
        #expect(!t.contains(Self.ip("192.168.1.10")))
    }

    @Test func sweepsA22() {
        let t = DeviceScanner.sweepTargets(ip: Self.ip("192.168.68.5"), netmask: Self.ip("255.255.252.0"))
        #expect(t.count == 1021)
        #expect(t.first == Self.ip("192.168.68.1"))
        #expect(t.last == Self.ip("192.168.71.254"))
    }

    /// /22 より広いサブネットは自分の /22 だけにする
    @Test func narrowsWiderSubnetsToA22() {
        let t = DeviceScanner.sweepTargets(ip: Self.ip("10.1.6.7"), netmask: Self.ip("255.0.0.0"))
        #expect(t.count == 1021)
        #expect(t.first == Self.ip("10.1.4.1"))
        #expect(t.last == Self.ip("10.1.7.254"))
    }

    /// iPhone のテザリング（192.0.0.2/32）などには相手がいない
    @Test func noPeersOnPointToPointLinks() {
        #expect(DeviceScanner.sweepTargets(ip: Self.ip("192.0.0.2"), netmask: Self.ip("255.255.255.255")).isEmpty)
        #expect(DeviceScanner.sweepTargets(ip: Self.ip("192.0.0.2"), netmask: Self.ip("255.255.255.254")).isEmpty)
        #expect(DeviceScanner.sweepTargets(ip: Self.ip("192.0.0.1"), netmask: Self.ip("255.255.255.252")) == [Self.ip("192.0.0.2")])
    }

    @Test(arguments: [
        ("Doorbell\\032Repeater-0A01.local.\n", "Doorbell Repeater-0A01"),
        ("iPhone.local.\n", "iPhone"),
        ("router.example.jp.\n", "router.example.jp"),
        ("\n;; connection timed out; no servers could be reached\nMacBook-Air.local.\n", "MacBook-Air"),
        ("Printer\\.2F.local.\n", "Printer.2F"),
        ("back\\\\slash.local.\n", "back\\slash"),
    ])
    func hostNameFromDig(output: String, name: String) {
        #expect(DeviceScanner.hostName(fromDig: output) == name)
    }

    /// dig は ASCII 以外を UTF-8 の1バイトずつ `\DDD` で書く
    @Test func unescapesMultibyteNames() {
        let name = "リビングのTV"
        let escaped = name.utf8.map { $0 < 0x80 ? String(UnicodeScalar($0)) : String(format: "\\%03d", $0) }.joined()
        #expect(DeviceScanner.hostName(fromDig: escaped + ".local.\n") == name)
    }

    @Test func noNameFromEmptyOutput() {
        #expect(DeviceScanner.hostName(fromDig: "") == nil)
        #expect(DeviceScanner.hostName(fromDig: ";; connection timed out\n") == nil)
    }
}
