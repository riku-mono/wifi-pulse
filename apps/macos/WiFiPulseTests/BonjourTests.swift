import Foundation
import Testing
@testable import WiFiPulse

struct BonjourTests {
    @Test func displayName() {
        #expect(Bonjour.displayName(instance: "Living Room", type: "_airplay._tcp", txt: [:]) == "Living Room")
        // AirPlay の音声は「MAC@名前」
        #expect(Bonjour.displayName(instance: "02418F5E9438@Living Room", type: "_raop._tcp", txt: [:]) == "Living Room")
        // Chromecast のインスタンス名は識別子なので、TXT の fn を使う
        #expect(Bonjour.displayName(instance: "Chromecast-0123abcd", type: "_googlecast._tcp", txt: ["fn": "Bedroom TV"]) == "Bedroom TV")
        // 数字だけ（iPhone の companion-link など）は名前にしない
        #expect(Bonjour.displayName(instance: "3303", type: "_companion-link._tcp", txt: [:]) == nil)
        #expect(Bonjour.displayName(instance: " ", type: "_smb._tcp", txt: [:]) == nil)
    }

    @Test func model() {
        #expect(Bonjour.model(type: "_airplay._tcp", txt: ["model": "AppleTV14,1"]) == "AppleTV14,1")
        #expect(Bonjour.model(type: "_raop._tcp", txt: ["md": "0,1,2", "am": "AudioAccessory5,1"]) == "AudioAccessory5,1")
        #expect(Bonjour.model(type: "_raop._tcp", txt: ["md": "0,1,2"]) == nil)
        #expect(Bonjour.model(type: "_hap._tcp", txt: ["md": "Doorbell"]) == "Doorbell")
        #expect(Bonjour.model(type: "_ipp._tcp", txt: ["ty": "Printer"]) == nil)
    }

    @Test func lanAddressesOnly() {
        #expect(Bonjour.isLANAddress([192, 168, 1, 10]))
        #expect(Bonjour.isLANAddress([10, 0, 0, 5]))
        #expect(!Bonjour.isLANAddress([127, 0, 0, 1]))
        #expect(!Bonjour.isLANAddress([169, 254, 3, 4]))
        #expect(!Bonjour.isLANAddress([224, 0, 0, 251]))
        #expect(!Bonjour.isLANAddress([0, 0, 0, 0]))
    }

    @Test func shortType() {
        #expect(Bonjour.shortType("_airplay._tcp") == "airplay")
        #expect(Bonjour.shortType("_companion-link._tcp") == "companion-link")
    }

    /// 同じ IP のサービスは1台にまとめ、名前は優先度の高いサービスのものを使う
    @Test func groupPrefersHigherRankedNames() {
        let g = Bonjour.group([
            (ip: "192.168.1.51", rank: 4, type: "_raop._tcp", name: "Speaker Name", model: nil),
            (ip: "192.168.1.51", rank: 0, type: "_airplay._tcp", name: "Living Room", model: "AppleTV14,1"),
            (ip: "192.168.1.51", rank: 1, type: "_companion-link._tcp", name: nil, model: nil),
            (ip: "192.168.1.57", rank: 6, type: "_ipp._tcp", name: "Printer", model: nil),
        ])
        #expect(g.count == 2)
        #expect(g["192.168.1.51"]?.name == "Living Room")
        #expect(g["192.168.1.51"]?.model == "AppleTV14,1")
        #expect(g["192.168.1.51"]?.services == ["airplay", "raop", "companion-link"])
        #expect(g["192.168.1.57"]?.services == ["ipp"])
    }
}

struct DeviceBonjourMergeTests {
    static let mac = "aa:bb:cc:00:00:01"

    /// ARP 表に同じ IP があれば MAC の登録に、無ければ `ip:…` の登録に入れる
    @Test func mergeKeysByMACWhenARPKnowsTheIP() {
        var registry = [Self.mac: Device(mac: Self.mac, ip: "192.168.1.51", first: 1, last: 1)]
        let found = [
            "192.168.1.51": BonjourDevice(name: "Living Room", model: "AppleTV14,1", services: ["airplay"]),
            "192.168.1.57": BonjourDevice(name: "Printer", services: ["ipp"]),
        ]
        let keys = DeviceScanner.mergeBonjour(found, arp: ["192.168.1.51": Self.mac], into: &registry, net: "n", now: 10)
        #expect(Set(keys) == [Self.mac, "ip:192.168.1.57"])
        #expect(registry[Self.mac]?.service == "Living Room")
        #expect(registry[Self.mac]?.first == 1)
        #expect(registry["ip:192.168.1.57"]?.hasMAC == false)
        #expect(registry["ip:192.168.1.57"]?.net == "n")
        #expect(registry["ip:192.168.1.57"]?.services == ["ipp"])
    }

    /// あとで ARP 表に出たら MAC の登録に移し、付けた名前も移す
    @Test func adoptMovesIPEntriesToTheMAC() {
        var registry = [
            "ip:192.168.1.57": Device(mac: "ip:192.168.1.57", ip: "192.168.1.57", first: 5, last: 9, service: "Printer", services: ["ipp"]),
            Self.mac: Device(mac: Self.mac, ip: "192.168.1.57", first: 8, last: 9),
        ]
        var names = ["ip:192.168.1.57": "Office Printer"]
        let moved = DeviceScanner.adoptIPEntries(arp: ["192.168.1.57": Self.mac], registry: &registry, names: &names)
        #expect(moved == ["ip:192.168.1.57"])
        #expect(registry.count == 1)
        #expect(registry[Self.mac]?.service == "Printer")
        #expect(registry[Self.mac]?.services == ["ipp"])
        #expect(registry[Self.mac]?.first == 5)
        #expect(names == [Self.mac: "Office Printer"])
    }

    /// ARP 表にまだ無い `ip:…` はそのまま
    @Test func adoptKeepsUnknownIPs() {
        var registry = ["ip:192.168.1.57": Device(mac: "ip:192.168.1.57", ip: "192.168.1.57", first: 5, last: 9)]
        var names: [String: String] = [:]
        #expect(DeviceScanner.adoptIPEntries(arp: [:], registry: &registry, names: &names).isEmpty)
        #expect(registry.count == 1)
    }

    @Test func classifyUsesServicesAndModel() {
        let env = NetworkEnvironment()
        func kind(_ d: Device) -> String { DeviceScanner.classify(d, env: env).1 }
        #expect(kind(Device(mac: "ip:1", first: 0, last: 0, services: ["ipp"])) == "printer")
        #expect(kind(Device(mac: "ip:1", first: 0, last: 0, services: ["hap"])) == "iot")
        // AirPlay を受けられる Mac は機種で見分ける
        #expect(kind(Device(mac: "ip:1", first: 0, last: 0, model: "Mac16,12", services: ["airplay", "raop"])) == "pc")
        #expect(kind(Device(mac: "ip:1", first: 0, last: 0, model: "AppleTV14,1", services: ["airplay"])) == "media")
        #expect(kind(Device(mac: "ip:1", first: 0, last: 0, model: "AudioAccessory5,1", services: ["airplay"])) == "speaker")
    }

    /// 古い記録に残ったエスケープ（`\032` は空白）を読み込むときに戻す
    @Test func repairsStoredDevices() {
        let old = [Self.mac: Device(mac: Self.mac, first: 0, last: 0, mdns: #"Doorbell\032Repeater-0A01"#)]
        #expect(DeviceScanner.repaired(old)[Self.mac]?.mdns == "Doorbell Repeater-0A01")
        let plain = [Self.mac: Device(mac: Self.mac, first: 0, last: 0, mdns: "Living-Room")]
        #expect(DeviceScanner.repaired(plain)[Self.mac]?.mdns == "Living-Room")
        // この Mac 自身がループバックで登録されたものは除く
        let loopback = ["ip:127.0.0.1": Device(mac: "ip:127.0.0.1", ip: "127.0.0.1", first: 0, last: 0)]
        #expect(DeviceScanner.repaired(loopback).isEmpty)
    }

    @Test func decodesDevicesWithoutBonjourFields() throws {
        let json = #"{"aa:bb:cc:00:00:01":{"first":1,"last":2,"mac":"aa:bb:cc:00:00:01"}}"#
        let d = try JSONDecoder().decode([String: Device].self, from: Data(json.utf8))
        #expect(d[Self.mac]?.service == nil)
        #expect(d[Self.mac]?.hasMAC == true)
    }
}
