import Foundation
import Synchronization
import Testing
@testable import WiFiPulse

/// パーサーが送り出したサンプルを受け取る
nonisolated final class SampleCollector: Sendable {
    private let samples = Mutex<[ProcessSample]>([])

    func append(_ s: ProcessSample) { samples.withLock { $0.append(s) } }

    /// `count` 件そろうまで待つ（パーサーは自分のキューで動くので）
    func wait(for count: Int, timeout: Duration = .seconds(3)) async -> [ProcessSample] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let s = samples.withLock { $0 }
            if s.count >= count { return s }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return samples.withLock { $0 }
    }
}

struct NettopParserTests {
    static let header = ",interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,\n"

    /// 3サンプル＋次のサンプルのヘッダ。最後のヘッダで3つ目までが確定するので、タイマーを待たずに結果が決まる。
    /// 1つ目は起動時点までの累計（大きな値）で、使われないはず
    static let fixture = header + """
        Safari.501,,,999999,999999,0,0,999,,
        tcp4 192.168.1.2:52000<->203.0.113.5:443,en0,Established,999999,999999,0,0,999,12.50 ms,
        mDNSResponder.300,,,999999,999999,0,0,0,,
        udp6 fe80::1%en0.5353<->*.*,en0,,999999,999999,0,0,0,,

        """ + header + """
        Safari.501,,,1000,2000,0,0,5,,
        tcp4 192.168.1.2:52000<->203.0.113.5:443,en0,Established,900,1800,0,0,5,12.50 ms,
        mDNSResponder.300,,,100,200,0,0,0,,
        udp6 fe80::1%en0.5353<->*.*,en0,,100,200,0,0,0,,

        """ + header + """
        Safari.501,,,3000,4000,0,0,1,,
        tcp4 192.168.1.2:52000<->203.0.113.5:443,en0,Established,3000,4000,0,0,1,20.00 ms,
        mDNSResponder.300,,,0,0,0,0,0,,
        udp6 fe80::1%en0.5353<->*.*,en0,,0,0,0,0,0,,

        """ + header

    func run(_ chunks: [Data]) async -> [ProcessSample] {
        let collector = SampleCollector()
        let parser = NettopParser(interval: 2) { collector.append($0) }
        for c in chunks { parser.feed(c) }
        return await collector.wait(for: 2)
    }

    @Test func usesDeltasFromTheSecondSampleOn() async throws {
        let samples = await run([Data(Self.fixture.utf8)])
        try #require(samples.count == 2)

        let safari = try #require(samples[0].processes.first { $0.pid == 501 })
        #expect(safari.name == "Safari")
        #expect(safari.rxRate == 500)
        #expect(safari.txRate == 1000)
        #expect(safari.rxTotal == 1000)
        #expect(safari.retransmitTotal == 5)

        // 累計は2つ目以降の差分の合計
        let later = try #require(samples[1].processes.first { $0.pid == 501 })
        #expect(later.rxTotal == 4000)
        #expect(later.txTotal == 6000)
        #expect(later.retransmitTotal == 6)
        let conn = try #require(later.connections.first)
        #expect(conn.rxTotal == 3900)
        #expect(conn.rttMs == 20)
    }

    @Test func parsesConnectionLines() async throws {
        let samples = await run([Data(Self.fixture.utf8)])
        let first = try #require(samples.first)

        let tcp = try #require(first.processes.first { $0.pid == 501 }?.connections.first)
        #expect(tcp.proto == "TCP")
        #expect(tcp.family == "IPv4")
        #expect(tcp.localHost == "192.168.1.2")
        #expect(tcp.localPort == "52000")
        #expect(tcp.remoteHost == "203.0.113.5")
        #expect(tcp.remotePort == "443")
        #expect(tcp.interface == "en0")
        #expect(tcp.state == "Established")
        #expect(tcp.rttMs == 12.5)
        #expect(!tcp.isListening)

        let udp = try #require(first.processes.first { $0.pid == 300 }?.connections.first)
        #expect(udp.proto == "UDP")
        #expect(udp.family == "IPv6")
        #expect(udp.localHost == "fe80::1")
        #expect(udp.localPort == "5353")
        #expect(udp.isListening)
    }

    /// 疑似端末やパイプからは任意の位置で切れて届く。どこで切れても同じサンプルになる
    @Test(arguments: [1, 2, 3, 7, 16, 61, 100])
    func sameSamplesRegardlessOfChunking(size: Int) async throws {
        let whole = await run([Data(Self.fixture.utf8)])
        let bytes = Data(Self.fixture.utf8)
        let chunks = stride(from: 0, to: bytes.count, by: size).map { bytes[$0..<min($0 + size, bytes.count)] }
        let split = await run(chunks.map { Data($0) })
        try #require(whole.count == 2 && split.count == 2)
        #expect(split.map(\.processes) == whole.map(\.processes))
    }

    @Test func stripsCarriageReturns() async throws {
        let crlf = Self.fixture.replacingOccurrences(of: "\n", with: "\r\n")
        let samples = await run([Data(crlf.utf8)])
        let plain = await run([Data(Self.fixture.utf8)])
        try #require(samples.count == 2)
        #expect(samples.map(\.processes) == plain.map(\.processes))
    }

    /// 出力が途切れたらいったん送り、同じサンプルの続きが届いたら同じ日時で送り直す
    @Test func resendsALateContinuationWithTheSameDate() async throws {
        let collector = SampleCollector()
        let parser = NettopParser(interval: 2) { collector.append($0) }
        parser.feed(Data((Self.header + "Safari.501,,,1,1,0,0,0,,\n" + Self.header + "Safari.501,,,1000,2000,0,0,0,,\n").utf8))

        let first = await collector.wait(for: 1)
        try #require(first.count == 1)
        #expect(first[0].processes.first?.connections.isEmpty == true)

        parser.feed(Data("tcp4 192.168.1.2:52000<->203.0.113.5:443,en0,Established,900,1800,0,0,0,,\n".utf8))
        let both = await collector.wait(for: 2)
        try #require(both.count == 2)
        #expect(both[1].date == both[0].date)
        #expect(both[1].processes.first?.connections.count == 1)
    }

    @Test(arguments: [
        ("192.168.1.2:443", false, "192.168.1.2", "443"),
        ("*:*", false, "*", "*"),
        ("fe80::1%en0.55396", true, "fe80::1", "55396"),
        ("2001:db8::1.443", true, "2001:db8::1", "443"),
        ("*.*", true, "*", "*"),
    ])
    func splitsHostAndPort(input: String, v6: Bool, host: String, port: String) {
        let (h, p) = NettopParser.split(input, v6: v6)
        #expect(h == host)
        #expect(p == port)
    }
}
