import Foundation
import Testing
@testable import WiFiPulse

nonisolated let noIE = InformationElements()

nonisolated func ie(offset: Int? = nil, vhtWidth: Int? = nil, center0: Int? = nil, center1: Int? = nil) -> InformationElements {
    var ie = InformationElements()
    ie.secondaryOffset = offset
    ie.vhtWidth = vhtWidth
    ie.vhtCenter0 = center0
    ie.vhtCenter1 = center1
    return ie
}

struct ChannelGeometryTests {
    @Test(arguments: [
        // 20MHz はプライマリそのもの
        (Band.ghz24, 6, 20, noIE, 6.0),
        (Band.ghz5, 36, 20, noIE, 36.0),
        // 2.4GHz 40MHz: IE が無ければ 1〜7 は上、8〜 は下に広げる
        (Band.ghz24, 1, 40, noIE, 3.0),
        (Band.ghz24, 11, 40, noIE, 9.0),
        (Band.ghz24, 6, 40, ie(offset: -1), 4.0),
        // 5GHz 40MHz
        (Band.ghz5, 36, 40, noIE, 38.0),
        (Band.ghz5, 40, 40, noIE, 38.0),
        (Band.ghz5, 44, 40, ie(offset: 1), 46.0),
        // 5GHz 80MHz
        (Band.ghz5, 36, 80, noIE, 42.0),
        (Band.ghz5, 48, 80, noIE, 42.0),
        (Band.ghz5, 149, 80, noIE, 155.0),
        (Band.ghz5, 52, 80, ie(vhtWidth: 1, center0: 58), 58.0),
        // 5GHz 160MHz
        (Band.ghz5, 36, 160, noIE, 50.0),
        (Band.ghz5, 100, 160, noIE, 114.0),
        (Band.ghz5, 36, 160, ie(vhtWidth: 1, center0: 42, center1: 50), 50.0),
        // 6GHz は 1,5,9… を帯域幅ごとに区切った中央
        (Band.ghz6, 5, 20, noIE, 5.0),
        (Band.ghz6, 1, 40, noIE, 3.0),
        (Band.ghz6, 5, 40, noIE, 3.0),
        (Band.ghz6, 13, 80, noIE, 7.0),
        (Band.ghz6, 33, 160, noIE, 47.0),
        (Band.ghz6, 1, 320, noIE, 31.0),
    ])
    func center(band: Band, primary: Int, width: Int, ie: InformationElements, expected: Double) {
        #expect(ChannelGeometry.center(primary: primary, width: width, band: band, ie: ie) == expected)
    }
}

struct InformationElementsTests {
    @Test func readsKnownElements() throws {
        let bytes: [UInt8] = [
            11, 5, 0x0C, 0x00, 0x80, 0, 0,   // BSS Load: 12台, 利用率 128/255
            45, 1, 0,                         // HT Capabilities
            61, 2, 36, 0x03,                  // HT Operation: 副チャンネルは下
            191, 1, 0,                        // VHT Capabilities
            192, 3, 1, 42, 0,                 // VHT Operation: 80MHz, 中心 42
            255, 1, 35,                       // HE Capabilities
            255, 1, 108,                      // EHT Capabilities
        ]
        let ie = InformationElements(Data(bytes))
        #expect(ie.stationCount == 12)
        #expect(ie.channelUtilization == 128.0 / 255)
        #expect(ie.hasHT)
        #expect(ie.secondaryOffset == -1)
        #expect(ie.hasVHT)
        #expect(ie.vhtWidth == 1)
        #expect(ie.vhtCenter0 == 42)
        #expect(ie.vhtCenter1 == 0)
        #expect(ie.hasHE)
        #expect(ie.hasEHT)
    }

    @Test func secondaryAbove() {
        #expect(InformationElements(Data([61, 2, 36, 0x01])).secondaryOffset == 1)
        #expect(InformationElements(Data([61, 2, 36, 0x00])).secondaryOffset == nil)
    }

    /// 長さが足りない要素・途中で切れたデータで落ちない
    @Test(arguments: [
        [UInt8](),
        [11],
        [11, 5, 1, 2],              // 本体が宣言より短い
        [11, 2, 1, 2],              // BSS Load として短すぎる
        [61, 1, 0],                 // HT Operation として短すぎる
        [192, 2, 1, 42],            // VHT Operation として短すぎる
        [255, 0],                   // 拡張 ID が無い
        [45, 1, 0, 11, 200, 1],     // 2つ目が途中で切れている
    ])
    func toleratesTruncatedData(bytes: [UInt8]) {
        let ie = InformationElements(Data(bytes))
        #expect(ie.stationCount == nil)
        #expect(ie.secondaryOffset == nil)
        #expect(ie.vhtWidth == nil)
        #expect(!ie.hasHE)
    }
}

struct ChannelLoadTests {
    static func ap(_ ssid: String?, band: Band, channel: Int, width: Int = 20, center: Double? = nil,
                   rssi: Int = -50, utilization: Double? = nil) -> AccessPoint {
        AccessPoint(id: UUID().uuidString, ssid: ssid, bssid: nil, band: band, channel: channel, width: width,
                    center: center ?? Double(channel), rssi: rssi, noise: -95, security: "WPA2", isInsecure: false,
                    generation: nil, beaconInterval: 100, country: nil, stations: nil, utilization: utilization,
                    vendor: nil, firstSeen: .now, lastSeen: .now)
    }

    static func load(_ loads: [ChannelLoad], _ ch: Int) -> ChannelLoad? { loads.first { $0.channel == ch } }

    /// 5GHz の隣のチャンネルは端が接しているだけなので、重なりとして数えない
    @Test func adjacent5GHzChannelsDoNotOverlap() {
        let loads = NeighborScanner.channelLoads([Self.ap("A", band: .ghz5, channel: 36)], band: .ghz5, mySSID: nil, myChannel: nil)
        #expect(Self.load(loads, 36)?.count == 1)
        #expect(Self.load(loads, 36)?.score == 1)
        #expect(Self.load(loads, 40)?.count == 0)
    }

    @Test func wideChannelsCoverEveryPrimaryInside() {
        let wide = Self.ap("A", band: .ghz5, channel: 36, width: 80, center: 42)
        let loads = NeighborScanner.channelLoads([wide], band: .ghz5, mySSID: nil, myChannel: nil)
        for ch in [36, 40, 44, 48] { #expect(Self.load(loads, ch)?.count == 1) }
        #expect(Self.load(loads, 52)?.count == 0)
    }

    /// 2.4GHz は 5MHz 間隔なので、20MHz 幅でも前後数チャンネルに部分的に重なる。遠いほど軽く数える
    @Test func overlapIn24GHzDecaysWithDistance() throws {
        let loads = NeighborScanner.channelLoads([Self.ap("A", band: .ghz24, channel: 1)], band: .ghz24, mySSID: nil, myChannel: nil)
        let at1 = try #require(Self.load(loads, 1)), at3 = try #require(Self.load(loads, 3))
        #expect(at1.score == 1)
        #expect(at3.count == 1)
        #expect(at3.score < at1.score)
        #expect(Self.load(loads, 6)?.count == 0)
    }

    @Test func skipsMyOwnNetworkAndMarksMyChannel() {
        let aps = [Self.ap("Home", band: .ghz5, channel: 36), Self.ap("Other", band: .ghz5, channel: 44)]
        let loads = NeighborScanner.channelLoads(aps, band: .ghz5, mySSID: "Home", myChannel: 36)
        #expect(Self.load(loads, 36)?.count == 0)
        #expect(Self.load(loads, 36)?.isMine == true)
        #expect(Self.load(loads, 44)?.count == 1)
        #expect(Self.load(loads, 44)?.isMine == false)
    }

    @Test func weakerAndIdleNetworksWeighLess() throws {
        let loads = NeighborScanner.channelLoads([
            Self.ap("Strong", band: .ghz5, channel: 36, rssi: -50),
            Self.ap("Weak", band: .ghz5, channel: 40, rssi: -80),
            Self.ap("Idle", band: .ghz5, channel: 44, rssi: -50, utilization: 0),
            Self.ap("Out of range", band: .ghz5, channel: 48, rssi: -100),
        ], band: .ghz5, mySSID: nil, myChannel: nil)
        #expect(try #require(Self.load(loads, 40)).score < 1)
        #expect(try #require(Self.load(loads, 44)).score == 0.5)
        #expect(try #require(Self.load(loads, 48)).score == 0)
    }

    /// 帯域の一覧に無いチャンネルの AP も表に加える
    @Test func includesChannelsOutsideTheList() {
        let loads = NeighborScanner.channelLoads([Self.ap("A", band: .ghz5, channel: 149)], band: .ghz5, mySSID: nil, myChannel: nil)
        #expect(Self.load(loads, 149)?.count == 1)
        #expect(loads.map(\.channel) == loads.map(\.channel).sorted())
    }

    @Test func recommendsNonDFSOnATie() {
        let loads = NeighborScanner.channelLoads([], band: .ghz5, mySSID: nil, myChannel: nil)
        #expect(NeighborScanner.recommendations(loads, band: .ghz5).map(\.channel) == [36, 40, 44])
    }

    @Test func recommendsDFSWhenTheOthersAreBusy() {
        let busy = Self.ap("A", band: .ghz5, channel: 36, width: 80, center: 42)
        let loads = NeighborScanner.channelLoads([busy], band: .ghz5, mySSID: nil, myChannel: nil)
        #expect(NeighborScanner.recommendations(loads, band: .ghz5).map(\.channel) == [52, 56, 60])
    }

    @Test func recommendsOnly1611In24GHz() {
        let loads = NeighborScanner.channelLoads([Self.ap("A", band: .ghz24, channel: 1)], band: .ghz24, mySSID: nil, myChannel: nil)
        #expect(NeighborScanner.recommendations(loads, band: .ghz24).map(\.channel) == [6, 11, 1])
    }
}
