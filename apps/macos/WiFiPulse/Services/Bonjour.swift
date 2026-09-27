import Foundation
import Network

/// Bonjour（mDNS / DNS-SD）でサービスを公開している機器。ARP 表が読めない署名でも見つけられる
nonisolated struct BonjourDevice: Equatable, Sendable {
    /// 表示に使う名前（サービスのインスタンス名。複数あれば `Bonjour.types` の先のものを優先）
    var name: String?
    /// 機種（`AppleTV14,1`・`Mac16,12`・`Chromecast` など。TXT レコードから）
    var model: String?
    /// 見つかったサービスの種類（`airplay`・`ipp` など。`_` と `._tcp` を外したもの）
    var services: Set<String> = []
}

/// よく使われるサービスを短い時間だけ探し、IPv4 アドレスごとに機器をまとめる。
/// 常時探し続けると mDNSResponder が動き続けるので、呼び出し側で回数を絞る
nonisolated enum Bonjour {
    /// 探すサービス。先にあるものほど名前として分かりやすい（Info.plist の NSBonjourServices にも同じものを並べる）
    static let types = [
        "_airplay._tcp", "_companion-link._tcp", "_googlecast._tcp", "_hap._tcp", "_raop._tcp",
        "_spotify-connect._tcp", "_ipp._tcp", "_ipps._tcp", "_pdl-datastream._tcp", "_smb._tcp",
    ]

    struct Result: Sendable {
        /// IPv4 アドレス → 機器
        var devices: [String: BonjourDevice] = [:]
        /// ローカルネットワークの許可が無く、探すことを拒否された
        var denied = false
    }

    /// `duration` の間探して、見つかった機器を返す
    static func discover(for duration: Duration = .seconds(4)) async -> Result {
        let session = Session()
        session.start()
        try? await Task.sleep(for: duration)
        return await session.finish()
    }

    /// 1回ぶんの探索。状態は `queue` の上でだけ触る
    private final class Session: @unchecked Sendable {
        private let queue = DispatchQueue(label: "WiFiPulse.bonjour")
        private var browsers: [NWBrowser] = []
        private var connections: [NWEndpoint: NWConnection] = [:]
        private var found: [(ip: String, service: Found)] = []
        private var denied = false

        struct Found {
            var rank: Int
            var type: String
            var name: String?
            var model: String?
        }

        func start() {
            queue.async { [self] in
                for (rank, type) in Bonjour.types.enumerated() {
                    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: NWParameters())
                    browser.stateUpdateHandler = { [self] state in
                        switch state {
                        case .failed(let e), .waiting(let e): if Bonjour.isPolicyDenied(e) { denied = true }
                        default: break
                        }
                    }
                    browser.browseResultsChangedHandler = { [self] results, _ in
                        for r in results where connections[r.endpoint] == nil { resolve(r, rank: rank, type: type) }
                    }
                    browser.start(queue: queue)
                    browsers.append(browser)
                }
            }
        }

        /// サービスの宛先を IPv4 アドレスに解決する。UDP の「接続」は解決するだけで相手には何も送らない
        private func resolve(_ result: NWBrowser.Result, rank: Int, type: String) {
            guard case .service(let instance, _, _, _) = result.endpoint else { return }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            let service = Found(rank: rank, type: type,
                                name: Bonjour.displayName(instance: instance, type: type, txt: txt),
                                model: Bonjour.model(type: type, txt: txt))
            let params = NWParameters.udp
            (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let connection = NWConnection(to: result.endpoint, using: params)
            connection.stateUpdateHandler = { [self, weak connection] state in
                guard case .ready = state, let connection else { return }
                if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint, let ip = Bonjour.ipv4(host) {
                    found.append((ip, service))
                }
                connection.cancel()
            }
            connections[result.endpoint] = connection
            connection.start(queue: queue)
        }

        func finish() async -> Result {
            await withCheckedContinuation { cont in
                queue.async { [self] in
                    browsers.forEach { $0.cancel() }
                    connections.values.forEach { $0.cancel() }
                    browsers.removeAll()
                    connections.removeAll()
                    cont.resume(returning: Result(devices: Bonjour.group(found.map { ($0.ip, $0.service.rank, $0.service.type, $0.service.name, $0.service.model) }),
                                                  denied: denied))
                }
            }
        }
    }

    // MARK: 解釈（純粋な関数）

    /// 見つかったサービス（IP・優先度・種類・名前・機種）を IP ごとにまとめる。名前・機種は優先度の高いサービスのものを使う
    static func group(_ services: [(ip: String, rank: Int, type: String, name: String?, model: String?)]) -> [String: BonjourDevice] {
        var out: [String: BonjourDevice] = [:]
        for s in services.sorted(by: { $0.rank < $1.rank }) {
            var d = out[s.ip] ?? BonjourDevice()
            if d.name == nil { d.name = s.name }
            if d.model == nil { d.model = s.model }
            d.services.insert(shortType(s.type))
            out[s.ip] = d
        }
        return out
    }

    /// `_airplay._tcp` → `airplay`
    static func shortType(_ type: String) -> String {
        String(type.split(separator: ".").first?.drop { $0 == "_" } ?? Substring(type))
    }

    /// 人が読める名前。AirPlay の音声（`_raop`）は `MAC@名前`、Chromecast は TXT の `fn` が名前。
    /// 数字だけの名前（iPhone の `_companion-link` など）は名前として使わない
    static func displayName(instance: String, type: String, txt: [String: String]) -> String? {
        var name = instance
        if type == "_googlecast._tcp", let fn = txt["fn"] { name = fn }
        if type == "_raop._tcp", let at = name.firstIndex(of: "@") { name = String(name[name.index(after: at)...]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.allSatisfy(\.isNumber) else { return nil }
        return name
    }

    /// TXT レコードの機種。キーはサービスごとに違う（`_raop` の `md` は機種ではない）
    static func model(type: String, txt: [String: String]) -> String? {
        let key = switch type {
        case "_airplay._tcp": "model"
        case "_raop._tcp": "am"
        case "_googlecast._tcp", "_hap._tcp": "md"
        default: ""
        }
        guard let v = txt[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }

    static func ipv4(_ host: NWEndpoint.Host) -> String? {
        guard case .ipv4(let a) = host else { return nil }
        let b = [UInt8](a.rawValue)
        guard b.count == 4 else { return nil }
        return b.map(String.init).joined(separator: ".")
    }

    /// ローカルネットワークの許可が無いときの拒否（kDNSServiceErr_PolicyDenied）
    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
        return false
    }
}
