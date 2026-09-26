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
