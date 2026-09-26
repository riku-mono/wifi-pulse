import Foundation
import Network
import Observation

/// 1秒ぶんの計測（生データ）。
nonisolated struct Tick: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let link: LinkSample?
    let gw: Pinger.Batch
    let v4: Pinger.Batch
    let v6: Pinger.Batch
    /// Wi-Fiインターフェースの受信・送信（bps）
    let rx: Double
    let tx: Double
    /// スコア・判定・1分集計から外す理由（グラフには残す）
    var excluded: Exclusion? = nil
}

/// その秒の計測をスコア・判定・1分集計から外す理由。
nonisolated enum Exclusion: Sendable, Hashable {
    /// 起動直後の慣らし運転（窓に十分なサンプルが溜まるまで判定しない）。
    /// この秒は履歴にも入れない（どの画面のグラフも、スコアと同じく慣らし運転の後から描く）
    case warmup
    /// LAN の掃引。約1000個の宛先へ ARP のブロードキャストが飛び、ルーター宛ての ping が
    /// 1〜2秒 100 ms 超に跳ねる・落ちる（家の Wi-Fi で 8 ms → 100〜160 ms を確認）
    case lanScan

    /// 判定を止めて理由を表示するか。数秒で終わるものは黙って外し、スコアは残りの秒から出す
    var pausesJudgement: Bool { self == .warmup }
}

/// 判定を止めている間の表示
struct JudgementPause: Equatable {
    var reason: Exclusion
    /// 0〜1。終わりが決まっていないときは nil
    var progress: Double?

    var title: String {
        switch reason {
        case .warmup: String(localized: "Getting Ready")
        case .lanScan: String(localized: "Scanning for Devices")
        }
    }

    var detail: String {
        switch reason {
        case .warmup: String(localized: "Waiting a few seconds after launch so start-up activity doesn’t affect the score.")
        case .lanScan: String(localized: "Looking for devices on your network. The score resumes shortly.")
        }
    }
}

nonisolated struct DNSSample: Identifiable, Hashable, Sendable {
    var id: Date { date }
    let date: Date
    let ms: Double?
}

/// 直近 N 秒の集計。
nonisolated struct WindowStats: Equatable, Sendable {
    var seconds: Int
    var gw: PingStats
    var v4: PingStats
    var v6: PingStats
    var rx: Double?
    var tx: Double?

    static func empty(_ seconds: Int) -> WindowStats {
        WindowStats(seconds: seconds, gw: .empty, v4: .empty, v6: .empty)
    }

    var isEmpty: Bool { gw.n + v4.n + gw.lost + v4.lost == 0 }
    var worstLoss: Double { max(gw.loss ?? 0, v4.loss ?? 0) }
    /// ルーター⇄インターネット区間の遅延（差分から推定）
    var wanP50: Double? {
        guard let a = v4.p50, let b = gw.p50 else { return nil }
        return max(0, a - b)
    }
}

/// 画面が毎秒読む「いまの状態」。1秒に1回だけ組み立て、ビューはこれを読むだけにする。
struct LiveSnapshot: Equatable {
    var date = Date.distantPast
    var link: LinkSample?
    var w30 = WindowStats.empty(30)
    var w60 = WindowStats.empty(60)
    var score: Int?
    var verdict = String(localized: "Measuring…")
    var level = Level.none
    var bottleneck = Analysis.Bottleneck(level: .none, tag: String(localized: "Evaluating"), text: String(localized: "Collecting data."), segment: nil)
    var rx: Double = 0
    var tx: Double = 0
    /// 判定を止めている間だけ入る（スコアは nil）
    var pause: JudgementPause?
}

/// 接続先（SSID・チャンネル）。変化したときだけ更新する。
struct ConnectionInfo: Equatable {
    var ssid: String?
    var bssid: String?
    var band: String?
    var channel: Int?
}

/// メニューバーのアイコン用。変化したときだけ更新する。
struct MenuState: Hashable {
    var level = Level.none
    var bars = 0
    var connected = false
}

/// 常時計測の本体。アプリ起動中はウインドウを閉じても動き続ける。
///
/// 描画負荷を抑えるため、観測されるプロパティは「変化したときだけ」書き換える:
/// - `live` … 毎秒（概要・メニューバーのパネルなど、いまの値を見る画面が読む）
/// - `revision` … 毎秒（履歴グラフを描く画面が読む。履歴本体は観測対象外）
/// - `menu` / `networkTitle` … 値が変わったときだけ（常に表示されている部分用）
@Observable
final class Monitor {
    static let historySeconds = 3600
    /// 起動後、判定を始めるまでの秒数。掃引（起動の直後に走り、約3秒で終わる）とその後の乱れが収まり、
    /// 窓にルーター宛て 50 発ほどが溜まるまで
    static let warmupSeconds: TimeInterval = 10

    private(set) var env = NetworkEnvironment()
    private(set) var live = LiveSnapshot()
    private(set) var menu = MenuState()
    private(set) var networkTitle = String(localized: "Checking connection")
    private(set) var connection = ConnectionInfo()
    private(set) var revision = 0
    private(set) var dns: [DNSSample] = []
    private(set) var isRunning = false
    private(set) var pathStatus = String(localized: "Checking connection")
    /// 保存された1分集計が更新されるたびに増える（時間帯グラフの再読み込み用）
    private(set) var minuteRevision = 0
    /// いまのネットワークの識別子。切り替わったときだけ変わる
    private(set) var network: String?
    /// これまでに計測したネットワーク
    private(set) var networks: [String: KnownNetwork] = [:]

    let devices = DeviceScanner()

    /// 直近1時間の生データ。観測対象外（`revision` を読んだビューが必要なときに参照する）。
    @ObservationIgnored private(set) var history: [Tick] = []
    @ObservationIgnored private var pingers: [String: Pinger] = [:]
    @ObservationIgnored private var minuteBuffer: [Tick] = []
    @ObservationIgnored private var previousCounters: InterfaceCounters.Reading?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var warmupEnd: Date?

    var inet4Target: String { UserDefaults.standard.string(forKey: "inet4Target") ?? "1.1.1.1" }
    var inet6Target: String { UserDefaults.standard.string(forKey: "inet6Target") ?? "2001:4860:4860::8888" }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        networks = DataStore.readJSON(DataStore.networks, as: [String: KnownNetwork].self) ?? [:]
        Task {
            env = await NetworkEnvironment.resolve()
            network = env.networkID
            registerNetwork()
            restartPingers()
            warmupEnd = Date().addingTimeInterval(Self.warmupSeconds)
            devices.start(monitor: self)
            loops.append(Task { await tickLoop() })
            loops.append(Task { await dnsLoop() })
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let text = switch path.status {
            case .satisfied: path.usesInterfaceType(.wifi) ? String(localized: "Wi-Fi") : path.usesInterfaceType(.wiredEthernet) ? String(localized: "Wired") : String(localized: "Connected")
            case .unsatisfied: String(localized: "Not connected")
            default: String(localized: "Checking connection")
            }
            let at = Date()
            Task { @MainActor in await self?.networkChanged(text, at: at) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "WiFiPulse.path"))
    }

    private func networkChanged(_ status: String, at: Date) async {
        if pathStatus != status { pathStatus = status }
        guard isRunning else { return }
        var fresh = await NetworkEnvironment.resolve()
        // ARP が一時的に引けなくても、ゲートウェイが同じならルーターは変わっていないとみなす
        if fresh.routerMAC.isEmpty, fresh.gateway == env.gateway { fresh.routerMAC = env.routerMAC }
        if fresh != env {
            env = fresh
            // 切断中（識別子なし）は区切らない。一瞬切れて同じネットワークに戻っても履歴は続ける
            if let id = fresh.networkID, id != network {
                if network == "ip:\(fresh.gateway)" {
                    // ルーターの MAC が後から取れた（ローカルネットワークの許可など）。同じネットワークとして続ける
                    network = id
                    registerNetwork()
                } else {
                    switchNetwork(to: id, at: at)
                }
            }
            restartPingers()
        }
    }

    /// 前のネットワークの計測を新しいネットワークに混ぜない。
    /// 変化に気づいた時点（`at`）より前の生データは前のネットワークの分として書き出し、履歴からも外す。
    private func switchNetwork(to id: String, at boundary: Date) {
        let old = network
        flushMinute(minuteBuffer.filter { $0.date < boundary }, network: old)
        minuteBuffer.removeAll { $0.date < boundary }
        history.removeAll { $0.date < boundary }
        dns.removeAll()
        network = id
        registerNetwork()
        revision &+= 1
    }

    nonisolated static let minimumPartialMinute = 10

    private func registerNetwork() {
        guard let id = network, networks[id]?.gateway != env.gateway else { return }
        var n = networks[id] ?? KnownNetwork(id: id, gateway: env.gateway, first: Date().epochMs)
        n.gateway = env.gateway
        networks[id] = n
        saveNetworks()
    }

    private func saveNetworks() {
        let snapshot = networks
        Task.detached(priority: .utility) { DataStore.writeJSON(snapshot, to: DataStore.networks) }
    }

    /// 設定で記録を消したとき。いまのネットワークだけ残す
    func recordsDeleted() {
        networks = networks.filter { $0.key == network }
        saveNetworks()
        minuteRevision += 1
    }

    private func restartPingers() {
        pingers.values.forEach { $0.stop() }
        pingers = [
            "gw": Pinger(host: env.gateway, interval: 0.2),
            "v4": Pinger(host: inet4Target, interval: 0.5),
            "v6": Pinger(host: inet6Target, interval: 1.0, v6: true),
        ]
        pingers.values.forEach { $0.start() }
        previousCounters = nil
    }

    /// 設定で宛先が変わったとき
    func applyTargets() { if isRunning { restartPingers() } }

    // MARK: Tick

    private func tickLoop() async {
        while !Task.isCancelled {
            let now = Date().timeIntervalSince1970
            try? await Task.sleep(for: .seconds(1.0 - now.truncatingRemainder(dividingBy: 1.0)))
            // CoreWLAN・カウンタ・ping の取り出しはメインスレッドの外で行う
            let raw = await Self.collect(interface: env.interface, pingers: pingers)
            apply(raw)
        }
    }

    nonisolated struct RawSample: Sendable {
        let date: Date
        let link: LinkSample?
        let counters: InterfaceCounters.Reading?
        let gw: Pinger.Batch, v4: Pinger.Batch, v6: Pinger.Batch
    }

    @concurrent
    nonisolated static func collect(interface: String, pingers: [String: Pinger]) async -> RawSample {
        RawSample(date: Date(), link: WiFiLink.sample(), counters: InterfaceCounters.read(interface),
                  gw: pingers["gw"]?.drain() ?? .init(),
                  v4: pingers["v4"]?.drain() ?? .init(),
                  v6: pingers["v6"]?.drain() ?? .init())
    }

    private func apply(_ raw: RawSample) {
        var rx = 0.0, tx = 0.0
        if let cur = raw.counters {
            if let prev = previousCounters {
                let dt = cur.at.timeIntervalSince(prev.at)
                if dt > 0 {
                    rx = Double(cur.rx &- prev.rx) * 8 / dt
                    tx = Double(cur.tx &- prev.tx) * 8 / dt
                }
            }
            previousCounters = cur
        }

        let excluded = exclusion(at: raw.date)
        let t = Tick(date: raw.date, link: raw.link, gw: raw.gw, v4: raw.v4, v6: raw.v6, rx: rx, tx: tx, excluded: excluded)
        if excluded != .warmup {
            history.append(t)
            // 1秒ごとに先頭を消すと O(n) なので、まとめて消す
            if history.count > Self.historySeconds + 300 { history.removeFirst(history.count - Self.historySeconds) }

            minuteBuffer.append(t)
            if minuteBuffer.count >= 60 {
                flushMinute(minuteBuffer, network: network)
                minuteBuffer.removeAll(keepingCapacity: true)
            }
        }

        // --- 観測されるプロパティの更新（毎秒1回） ---
        var s = LiveSnapshot()
        s.date = raw.date
        s.link = raw.link
        s.w30 = window(30)
        s.w60 = window(60)
        s.score = Analysis.score(s.w30, link: s.link)
        (s.verdict, s.level) = Analysis.verdict(s.score)
        s.bottleneck = Analysis.bottleneck(s.w60, link: s.link)
        s.rx = rx
        s.tx = tx
        if let excluded, excluded.pausesJudgement {
            // 窓は空（スコアは nil）。何を待っているかと進み具合を出す
            s.pause = JudgementPause(reason: excluded, progress: warmupEnd.map { Self.progress(at: raw.date, end: $0, length: Self.warmupSeconds) })
            s.verdict = s.pause?.title ?? s.verdict
        }
        live = s
        revision &+= 1

        let m = MenuState(level: s.level, bars: raw.link?.bars ?? 0, connected: raw.link?.powerOn == true)
        if m != menu { menu = m }
        let title: String = {
            guard let link = raw.link, link.powerOn else { return pathStatus }
            return "\(link.ssid ?? "Wi-Fi") · \(link.bandLabel) ch\(link.channel.map(String.init) ?? "—")"
        }()
        if title != networkTitle { networkTitle = title }
        let c = ConnectionInfo(ssid: raw.link?.ssid, bssid: raw.link?.bssid, band: raw.link?.band, channel: raw.link?.channel)
        if c != connection { connection = c }
        // SSID は位置情報の許可があるときだけ取れる。取れたらネットワークの表示名にする
        if let id = network, let ssid = c.ssid, !ssid.isEmpty, networks[id] != nil, networks[id]?.ssid != ssid {
            networks[id]?.ssid = ssid
            saveNetworks()
        }
    }

    private func flushMinute(_ ts: [Tick], network: String?) {
        guard let row = Self.minuteRow(ts, network: network) else { return }
        Task.detached(priority: .utility) { DataStore.append(row, to: DataStore.minutes) }
        minuteRevision += 1
    }

    /// 1分ぶんの生データを集計する。外す秒（`Tick.excluded`）は除き、残りが数秒だけなら意味が無いので nil
    nonisolated static func minuteRow(_ all: [Tick], network: String?) -> MinuteRow? {
        let ts = all.filter { $0.excluded == nil }
        guard ts.count >= minimumPartialMinute else { return nil }
        func pct(_ kp: KeyPath<Tick, Pinger.Batch>, _ q: Double) -> Double? {
            percentile(ts.flatMap { $0[keyPath: kp].rtts }.sorted(), q)
        }
        func loss(_ kp: KeyPath<Tick, Pinger.Batch>) -> Double? {
            let recv = ts.reduce(0) { $0 + $1[keyPath: kp].rtts.count }
            let lost = ts.reduce(0) { $0 + $1[keyPath: kp].lost }
            return recv + lost == 0 ? nil : (Double(lost) / Double(recv + lost) * 10000).rounded() / 10000
        }
        let links = ts.compactMap(\.link)
        let first = ts[0].date
        return MinuteRow(
            t: first.epochMs, hour: first.hour, wd: first.pythonWeekday, n: ts.count,
            rssi: median(links.map { Double($0.rssi) }),
            rate: median(links.map(\.txRate)),
            gw50: pct(\.gw, 0.5), gw95: pct(\.gw, 0.95),
            v450: pct(\.v4, 0.5), v495: pct(\.v4, 0.95), v650: pct(\.v6, 0.5),
            lgw: loss(\.gw), lv4: loss(\.v4),
            rx: (ts.reduce(0) { $0 + $1.rx } / Double(ts.count)).rounded(),
            tx: (ts.reduce(0) { $0 + $1.tx } / Double(ts.count)).rounded(),
            net: network,
            bssid: links.last { $0.bssid != nil }?.bssid
        )
    }

    /// この秒を判定・集計から外すか
    private func exclusion(at date: Date) -> Exclusion? {
        if let warmupEnd, date < warmupEnd { return .warmup }
        if devices.isSweeping { return .lanScan }
        return nil
    }

    /// `end` まで `length` 秒かかるものの進み具合（0〜1）
    nonisolated static func progress(at date: Date, end: Date, length: TimeInterval) -> Double {
        min(1, max(0, 1 - end.timeIntervalSince(date) / length))
    }

    private func dnsLoop() async {
        while !Task.isCancelled {
            if !env.gateway.isEmpty {
                let out = await Shell.run("/usr/bin/dig", ["@\(env.gateway)", "www.apple.com", "+tries=1", "+time=2"], timeout: 5)
                let ms = out.firstMatch(of: #/Query time:\s*(\d+)/#).flatMap { Double($0.1) }
                var d = dns
                d.append(DNSSample(date: Date(), ms: ms))
                if d.count > 120 { d.removeFirst(d.count - 120) }
                dns = d
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    // MARK: Aggregates

    /// 直近 `seconds` 秒の生データ
    func recent(_ seconds: Int) -> ArraySlice<Tick> {
        guard let end = history.last?.date else { return [] }
        let from = end.addingTimeInterval(-Double(seconds) + 0.5)
        let start = history.lastIndex { $0.date < from }.map { $0 + 1 } ?? history.startIndex
        return history[start...]
    }

    /// 直近 `seconds` 秒の集計。判定から外す秒は除く
    func window(_ seconds: Int) -> WindowStats {
        Self.windowStats(recent(seconds), seconds: seconds)
    }

    nonisolated static func windowStats(_ ticks: some Collection<Tick>, seconds: Int) -> WindowStats {
        let slice = ticks.filter { $0.excluded == nil }
        guard !slice.isEmpty else { return .empty(seconds) }
        let n = Double(slice.count)
        return WindowStats(
            seconds: seconds,
            gw: PingStats(slice.flatMap(\.gw.rtts), lost: slice.reduce(0) { $0 + $1.gw.lost }),
            v4: PingStats(slice.flatMap(\.v4.rtts), lost: slice.reduce(0) { $0 + $1.v4.lost }),
            v6: PingStats(slice.flatMap(\.v6.rtts), lost: slice.reduce(0) { $0 + $1.v6.lost }),
            rx: slice.reduce(0) { $0 + $1.rx } / n,
            tx: slice.reduce(0) { $0 + $1.tx } / n
        )
    }
}
